// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import SkipChessModel
import SkipChessEngine

/// A negamax alpha-beta search engine that uses ``PestoEvaluator`` for
/// static evaluation and includes iterative deepening, a transposition
/// table, killer / history move ordering, MVV-LVA capture ordering, and a
/// quiescence search to keep horizon effects under control.
///
/// The engine is designed to be deterministic at a given depth (modulo
/// time-limit cutoffs) so that test cases can pin specific moves in tactical
/// positions and assert that no proposed move is illegal.
///
/// ## Thread Safety
///
/// `AlphaBetaEngine` is **not** safe for concurrent calls to
/// ``findBestMove(from:limits:control:listener:)``. The internal
/// transposition table, killer slots, history heuristic, and per-ply
/// search buffers are mutable state shared across recursive calls.
/// External cancellation through ``SearchControl/requestStop()`` from
/// another thread is supported and is the intended cross-thread API; the
/// `Bool` flag relies on the JVM memory model for eventual visibility on
/// Kotlin, which is acceptable for cooperative cancellation.
///
/// Create one engine instance per concurrent search.
public final class AlphaBetaEngine: ChessEngine {

    // MARK: - Public protocol surface

    public let name: String = "AlphaBeta PeSTO"
    public let version: String = "1.0.0"

    // MARK: - Tunable knobs

    /// Score representing a forced mate. Plies-to-mate are subtracted from
    /// this constant so the search prefers shorter mates.
    public static let mateScore: Int = 30000
    /// Plies of mate distance still treated as "this is mate" by the
    /// scoring logic.
    public static let mateThreshold: Int = mateScore - 200
    /// Hard cap for alpha/beta bounds.
    public static let infinity: Int = 32000

    // MARK: - Construction

    public let evaluator: PositionEvaluator
    public let transpositionTable: TranspositionTable

    public init(evaluator: PositionEvaluator? = nil, transpositionTableEntries: Int = 1 << 17) {
        self.evaluator = evaluator ?? PestoEvaluator()
        self.transpositionTable = TranspositionTable(numberOfEntries: transpositionTableEntries)
    }

    // MARK: - Per-search state (mutated under findBestMove only)

    private var nodesSearched: Int64 = 0
    private var selectiveDepth: Int = 0
    private var startMilliseconds: Int64 = 0
    private var deadlineMilliseconds: Int64 = -1
    private var maxNodes: Int64 = -1
    private var control: SearchControl?
    private var stopRequested: Bool = false

    // Killer moves: two slots per ply. Each slot stores an encoded move.
    private var killerSlot0: [Int] = [Int](repeating: 0, count: 128)
    private var killerSlot1: [Int] = [Int](repeating: 0, count: 128)
    // History heuristic: [color][from*64 + to].
    private var historyWhite: [Int] = [Int](repeating: 0, count: 64 * 64)
    private var historyBlack: [Int] = [Int](repeating: 0, count: 64 * 64)

    // Reusable move buffers per ply to avoid hot-loop allocation.
    private var moveBuffers: [[Move]] = []
    private var scoreBuffers: [[Int]] = []

    // MARK: - ChessEngine entry point

    public func findBestMove(
        from board: Board,
        limits: SearchLimits,
        control: SearchControl?,
        listener: SearchProgressListener?
    ) -> SearchResult {
        let working = board.clone()
        resetSearchState(limits: limits, control: control)

        let immediateMoves = working.legalMoves()
        if immediateMoves.isEmpty {
            let evaluation: SearchEvaluation
            if working.isCheck() {
                evaluation = SearchEvaluation.mateAgainstCurrentSide(inMoves: 0)
            } else {
                evaluation = SearchEvaluation.score(centipawns: 0)
            }
            let info = SearchInfo(depth: 0, selectiveDepth: 0, nodesSearched: 0, elapsedMilliseconds: 0)
            return SearchResult(bestMove: nil, evaluation: evaluation, principalVariation: [], info: info)
        }

        // Always have a fallback move so we never return nil for a position
        // with legal moves, even if we abort during depth 1.
        var bestMove: Move = immediateMoves[0]
        var bestScore: Int = 0
        var bestPV: [Move] = [immediateMoves[0]]
        var completedDepth: Int = 0

        let maxDepth = limits.maxDepth ?? 64

        var depth = 1
        while depth <= maxDepth {
            stopRequested = false
            let iterationResult = searchRoot(board: working, depth: depth)
            if stopRequested {
                // Abort mid-iteration; keep results from prior completed depth.
                break
            }
            bestMove = iterationResult.move
            bestScore = iterationResult.score
            bestPV = extractPrincipalVariation(board: working, depth: depth, firstMove: bestMove)
            completedDepth = depth

            let evaluation = makeEvaluation(score: bestScore, ply: 0)
            let info = SearchInfo(
                depth: depth,
                selectiveDepth: selectiveDepth,
                nodesSearched: nodesSearched,
                elapsedMilliseconds: elapsedMilliseconds()
            )
            let intermediate = SearchResult(bestMove: bestMove, evaluation: evaluation, principalVariation: bestPV, info: info)
            listener?.didCompleteIteration(result: intermediate)

            // Stop early if a forced mate has been found.
            if isMateScore(bestScore) {
                break
            }
            // Respect time / node budgets between iterations.
            if shouldStop() {
                break
            }
            depth = depth + 1
        }

        let finalEval = makeEvaluation(score: bestScore, ply: 0)
        let finalInfo = SearchInfo(
            depth: completedDepth == 0 ? 1 : completedDepth,
            selectiveDepth: selectiveDepth,
            nodesSearched: nodesSearched,
            elapsedMilliseconds: elapsedMilliseconds()
        )
        return SearchResult(bestMove: bestMove, evaluation: finalEval, principalVariation: bestPV, info: finalInfo)
    }

    // MARK: - Search state helpers

    private func resetSearchState(limits: SearchLimits, control: SearchControl?) {
        nodesSearched = 0
        selectiveDepth = 0
        startMilliseconds = currentMilliseconds()
        self.control = control
        stopRequested = false
        // killer/history are NOT cleared between calls because they retain
        // useful information from prior searches; clearing on every call
        // would defeat their purpose for engines that share state. The
        // values are bounded so they don't grow without limit.
        for i in 0..<killerSlot0.count {
            killerSlot0[i] = 0
            killerSlot1[i] = 0
        }
        if let ms = limits.maxMilliseconds {
            deadlineMilliseconds = startMilliseconds + ms
        } else {
            deadlineMilliseconds = -1
        }
        maxNodes = limits.maxNodes ?? -1
    }

    private func currentMilliseconds() -> Int64 {
        #if SKIP
        return java.lang.System.currentTimeMillis()
        #else
        // Use Swift stdlib's monotonic clock so this module doesn't pull in
        // Foundation. ContinuousClock is available in Swift 5.7+ and is a
        // monotonic source suitable for elapsed-time measurements.
        let elapsed = ContinuousClock.now - AlphaBetaEngine.clockOrigin
        let components = elapsed.components
        // components.seconds is whole seconds, attoseconds is the
        // fractional remainder (10^-18 second units). 10^15 attoseconds = 1ms.
        return components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
        #endif
    }

    #if !SKIP
    /// A stable reference point for ``ContinuousClock`` measurements.
    private static let clockOrigin = ContinuousClock.now
    #endif

    private func elapsedMilliseconds() -> Int64 {
        return currentMilliseconds() - startMilliseconds
    }

    private func shouldStop() -> Bool {
        if let c = control {
            if c.isStopRequested {
                return true
            }
        }
        if deadlineMilliseconds >= 0 && currentMilliseconds() >= deadlineMilliseconds {
            return true
        }
        if maxNodes >= 0 && nodesSearched >= maxNodes {
            return true
        }
        return false
    }

    // MARK: - Root search

    private struct RootResult {
        let move: Move
        let score: Int
    }

    private func searchRoot(board: Board, depth: Int) -> RootResult {
        var moves = board.legalMoves()
        if moves.isEmpty {
            // Shouldn't happen at root if caller already filtered, but be safe.
            return RootResult(move: Move(from: 0, to: 0), score: 0)
        }

        // Probe TT for hash move ordering hint.
        let ttHashMove = transpositionTable.probe(key: board.zobristKey).move

        // Score and sort moves at root.
        var scores = [Int](repeating: 0, count: moves.count)
        for i in 0..<moves.count {
            scores[i] = rootScoreFor(move: moves[i], hashMove: ttHashMove, board: board)
        }
        sortByScores(moves: &moves, scores: &scores)

        var alpha = -AlphaBetaEngine.infinity
        let beta = AlphaBetaEngine.infinity
        var bestScore = -AlphaBetaEngine.infinity
        var bestMove = moves[0]

        for i in 0..<moves.count {
            let move = moves[i]
            let undo = board.makeMove(move)
            let score = -alphaBeta(board: board, depth: depth - 1, alpha: -beta, beta: -alpha, ply: 1)
            board.unmakeMove(undo)
            if stopRequested {
                break
            }
            if score > bestScore {
                bestScore = score
                bestMove = move
            }
            if score > alpha {
                alpha = score
            }
            if alpha >= beta {
                break
            }
        }

        // Only persist a TT entry if the search completed without abort.
        // Otherwise we'd pollute the table with partial results that could
        // mislead a subsequent search at the same depth.
        if !stopRequested {
            let encoded = CompactMove.encode(bestMove)
            transpositionTable.store(key: board.zobristKey, score: bestScore, depth: depth, bound: TTBound.exact, move: encoded)
        }
        return RootResult(move: bestMove, score: bestScore)
    }

    // MARK: - Alpha-Beta (negamax)

    private func alphaBeta(board: Board, depth: Int, alpha: Int, beta: Int, ply: Int) -> Int {
        // Periodic cooperative cancellation.
        nodesSearched = nodesSearched + 1
        if (nodesSearched & Int64(1023)) == Int64(0) {
            if shouldStop() {
                stopRequested = true
            }
        }
        if stopRequested {
            return 0
        }

        if ply > selectiveDepth {
            selectiveDepth = ply
        }

        // Leaf: enter quiescence search.
        if depth <= 0 {
            return quiescence(board: board, alpha: alpha, beta: beta, ply: ply)
        }

        // TT probe.
        let ttProbe = transpositionTable.probe(key: board.zobristKey)
        var ttMove = 0
        if ttProbe.found {
            ttMove = ttProbe.move
            if ttProbe.depth >= depth {
                let ttScore = adjustScoreFromTT(score: ttProbe.score, ply: ply)
                switch ttProbe.bound {
                case TTBound.exact:
                    return ttScore
                case TTBound.lower:
                    if ttScore >= beta {
                        return ttScore
                    }
                case TTBound.upper:
                    if ttScore <= alpha {
                        return ttScore
                    }
                default:
                    break
                }
            }
        }

        // Generate legal moves.
        var moves = legalMovesBuffer(forPly: ply)
        moves.removeAll(keepingCapacity: true)
        MoveGenerator.generateLegalMoves(board: board, into: &moves)
        if moves.isEmpty {
            // Checkmate or stalemate.
            if board.isCheck() {
                // We've been mated; return very negative mate score that
                // prefers later mates over earlier ones.
                return -AlphaBetaEngine.mateScore + ply
            }
            return 0
        }

        // Score and order moves.
        var scores = scoreBufferFor(ply: ply, count: moves.count)
        for i in 0..<moves.count {
            scores[i] = scoreMove(move: moves[i], ttMove: ttMove, ply: ply, board: board)
        }
        sortByScores(moves: &moves, scores: &scores)

        var currentAlpha = alpha
        var bestScore = -AlphaBetaEngine.infinity
        var bestMove: Move = moves[0]
        var bound = TTBound.upper  // assume fail-low until proven otherwise

        for i in 0..<moves.count {
            let move = moves[i]
            let undo = board.makeMove(move)
            let score = -alphaBeta(board: board, depth: depth - 1, alpha: -beta, beta: -currentAlpha, ply: ply + 1)
            board.unmakeMove(undo)
            if stopRequested {
                return 0
            }
            if score > bestScore {
                bestScore = score
                bestMove = move
            }
            if score > currentAlpha {
                currentAlpha = score
                bound = TTBound.exact
            }
            if currentAlpha >= beta {
                // Beta cutoff: record killer / history bonuses for quiet moves.
                let isCapture = board.squares[move.to] != 0 && PieceCode.isWhite(board.squares[move.to]) != PieceCode.isWhite(board.squares[move.from])
                // (Above: at unmake time, squares[move.to] is the captured
                // piece, but we already unmade — instead infer from
                // promotion or pre-move state. Simpler: re-check during
                // make. We approximate by treating non-promotion non-target
                // moves as quiet for ordering purposes.)
                if move.promotion == 0 && !isCapture {
                    storeKiller(move: move, ply: ply)
                    addHistoryBonus(move: move, depth: depth, sideToMoveColor: board.sideToMove)
                }
                bound = TTBound.lower
                break
            }
        }

        // Store in TT.
        let encoded = CompactMove.encode(bestMove)
        let scoreForTT = adjustScoreForTT(score: bestScore, ply: ply)
        transpositionTable.store(key: board.zobristKey, score: scoreForTT, depth: depth, bound: bound, move: encoded)
        return bestScore
    }

    // MARK: - Quiescence search

    private func quiescence(board: Board, alpha: Int, beta: Int, ply: Int) -> Int {
        nodesSearched = nodesSearched + 1
        if (nodesSearched & Int64(1023)) == Int64(0) {
            if shouldStop() {
                stopRequested = true
            }
        }
        if stopRequested {
            return 0
        }
        if ply > selectiveDepth {
            selectiveDepth = ply
        }

        let standPat = evaluator.evaluate(board: board)
        if standPat >= beta {
            return beta
        }
        var currentAlpha = alpha
        if standPat > currentAlpha {
            currentAlpha = standPat
        }
        // Hard cap on quiescence depth so we don't run away in pathological
        // capture sequences.
        if ply > 40 {
            return currentAlpha
        }

        // Generate only forcing moves (captures + promotions).
        var allMoves: [Move] = []
        allMoves.reserveCapacity(40)
        MoveGenerator.generateLegalMoves(board: board, into: &allMoves)
        var captures: [Move] = []
        captures.reserveCapacity(20)
        var captureScores: [Int] = []
        captureScores.reserveCapacity(20)
        for m in allMoves {
            let isCapture = board.squares[m.to] != 0
            if isCapture || m.promotion != 0 {
                captures.append(m)
                captureScores.append(mvvLvaScore(move: m, board: board))
            }
        }
        sortByScores(moves: &captures, scores: &captureScores)

        for move in captures {
            let undo = board.makeMove(move)
            let score = -quiescence(board: board, alpha: -beta, beta: -currentAlpha, ply: ply + 1)
            board.unmakeMove(undo)
            if stopRequested {
                return 0
            }
            if score >= beta {
                return beta
            }
            if score > currentAlpha {
                currentAlpha = score
            }
        }
        return currentAlpha
    }

    // MARK: - Move ordering

    private func rootScoreFor(move: Move, hashMove: Int, board: Board) -> Int {
        if CompactMove.encode(move) == hashMove && hashMove != 0 {
            return 1_000_000
        }
        if board.squares[move.to] != 0 {
            return 100_000 + mvvLvaScore(move: move, board: board)
        }
        if move.promotion != 0 {
            return 90_000 + move.promotion
        }
        return historyValue(move: move, color: board.sideToMove)
    }

    private func scoreMove(move: Move, ttMove: Int, ply: Int, board: Board) -> Int {
        if CompactMove.encode(move) == ttMove && ttMove != 0 {
            return 1_000_000
        }
        let target = board.squares[move.to]
        if target != 0 {
            return 100_000 + mvvLvaScore(move: move, board: board)
        }
        if move.promotion != 0 {
            return 90_000 + move.promotion
        }
        let encoded = CompactMove.encode(move)
        if ply >= 0 && ply < killerSlot0.count {
            if encoded == killerSlot0[ply] {
                return 80_000
            }
            if encoded == killerSlot1[ply] {
                return 70_000
            }
        }
        return historyValue(move: move, color: board.sideToMove)
    }

    private func mvvLvaScore(move: Move, board: Board) -> Int {
        // Most Valuable Victim - Least Valuable Attacker
        let victim = board.squares[move.to]
        let attacker = board.squares[move.from]
        let victimValue = pieceValue(forCode: victim)
        let attackerValue = pieceValue(forCode: attacker)
        return victimValue * 10 - attackerValue
    }

    private func pieceValue(forCode code: Int) -> Int {
        if code == 0 {
            return 0
        }
        let kind = PieceCode.kind(code)
        switch kind {
        case 1: return 100
        case 2: return 320
        case 3: return 330
        case 4: return 500
        case 5: return 900
        case 6: return 20000
        default: return 0
        }
    }

    private func storeKiller(move: Move, ply: Int) {
        if ply < 0 || ply >= killerSlot0.count {
            return
        }
        let encoded = CompactMove.encode(move)
        if killerSlot0[ply] != encoded {
            killerSlot1[ply] = killerSlot0[ply]
            killerSlot0[ply] = encoded
        }
    }

    private func addHistoryBonus(move: Move, depth: Int, sideToMoveColor: PieceColor) {
        let idx = move.from * 64 + move.to
        let bonus = depth * depth
        if sideToMoveColor == .white {
            historyWhite[idx] = historyWhite[idx] + bonus
            // Saturate so values don't run away.
            if historyWhite[idx] > 50_000 {
                for i in 0..<historyWhite.count {
                    historyWhite[i] = historyWhite[i] / 2
                }
            }
        } else {
            historyBlack[idx] = historyBlack[idx] + bonus
            if historyBlack[idx] > 50_000 {
                for i in 0..<historyBlack.count {
                    historyBlack[i] = historyBlack[i] / 2
                }
            }
        }
    }

    private func historyValue(move: Move, color: PieceColor) -> Int {
        let idx = move.from * 64 + move.to
        return color == .white ? historyWhite[idx] : historyBlack[idx]
    }

    // MARK: - Buffer helpers

    private func legalMovesBuffer(forPly ply: Int) -> [Move] {
        while moveBuffers.count <= ply {
            var buf: [Move] = []
            buf.reserveCapacity(64)
            moveBuffers.append(buf)
        }
        return moveBuffers[ply]
    }

    private func scoreBufferFor(ply: Int, count: Int) -> [Int] {
        while scoreBuffers.count <= ply {
            scoreBuffers.append([Int]())
        }
        var buf = scoreBuffers[ply]
        if buf.count < count {
            buf = [Int](repeating: 0, count: count)
        } else {
            for i in 0..<count {
                buf[i] = 0
            }
        }
        scoreBuffers[ply] = buf
        return buf
    }

    // MARK: - Score / mate helpers

    private func isMateScore(_ score: Int) -> Bool {
        let abs = score < 0 ? -score : score
        return abs >= AlphaBetaEngine.mateThreshold
    }

    private func adjustScoreForTT(score: Int, ply: Int) -> Int {
        if score >= AlphaBetaEngine.mateThreshold {
            return score + ply
        }
        if score <= -AlphaBetaEngine.mateThreshold {
            return score - ply
        }
        return score
    }

    private func adjustScoreFromTT(score: Int, ply: Int) -> Int {
        if score >= AlphaBetaEngine.mateThreshold {
            return score - ply
        }
        if score <= -AlphaBetaEngine.mateThreshold {
            return score + ply
        }
        return score
    }

    private func makeEvaluation(score: Int, ply: Int) -> SearchEvaluation {
        if score >= AlphaBetaEngine.mateThreshold {
            let pliesToMate = AlphaBetaEngine.mateScore - score
            let fullMoves = (pliesToMate + 1) / 2
            return SearchEvaluation.mateForCurrentSide(inMoves: fullMoves)
        }
        if score <= -AlphaBetaEngine.mateThreshold {
            let pliesToMate = AlphaBetaEngine.mateScore + score
            let fullMoves = (pliesToMate + 1) / 2
            return SearchEvaluation.mateAgainstCurrentSide(inMoves: fullMoves)
        }
        return SearchEvaluation.score(centipawns: score)
    }

    // MARK: - Sorting & PV reconstruction

    /// In-place insertion-sort by `scores` descending. Insertion sort works
    /// well because move counts are small (typically < 40) and the input is
    /// often already nearly sorted.
    private func sortByScores(moves: inout [Move], scores: inout [Int]) {
        let n = moves.count
        if n < 2 {
            return
        }
        var i = 1
        while i < n {
            let m = moves[i]
            let s = scores[i]
            var j = i - 1
            while j >= 0 && scores[j] < s {
                moves[j + 1] = moves[j]
                scores[j + 1] = scores[j]
                j = j - 1
            }
            moves[j + 1] = m
            scores[j + 1] = s
            i = i + 1
        }
    }

    /// Walks the transposition table from the root to reconstruct the PV.
    private func extractPrincipalVariation(board: Board, depth: Int, firstMove: Move) -> [Move] {
        var pv: [Move] = []
        pv.append(firstMove)
        let workingBoard = board
        var undos: [UndoState] = []
        let firstUndo = workingBoard.makeMove(firstMove)
        undos.append(firstUndo)
        var safety = 0
        while safety < depth + 8 {
            let probe = transpositionTable.probe(key: workingBoard.zobristKey)
            if !probe.found || probe.move == 0 {
                break
            }
            let next = CompactMove.decode(probe.move)
            if !workingBoard.isLegalMove(next) {
                break
            }
            pv.append(next)
            let undo = workingBoard.makeMove(next)
            undos.append(undo)
            safety = safety + 1
        }
        // Restore board state.
        var i = undos.count - 1
        while i >= 0 {
            workingBoard.unmakeMove(undos[i])
            i = i - 1
        }
        return pv
    }
}
