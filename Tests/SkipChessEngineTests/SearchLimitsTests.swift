// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import SkipChessEngine
import SkipChessModel

@Suite struct SearchLimitsTests {

    @Test func unlimitedDefaults() throws {
        let limits = SearchLimits.unlimited
        #expect(limits.maxDepth == nil)
        #expect(limits.maxNodes == nil)
        #expect(limits.maxMilliseconds == nil)
    }

    @Test func depthFactory() throws {
        let limits = SearchLimits.depth(5)
        #expect(limits.maxDepth == 5)
        #expect(limits.maxNodes == nil)
        #expect(limits.maxMilliseconds == nil)
    }

    @Test func nodesFactory() throws {
        let limits = SearchLimits.nodes(10000)
        #expect(limits.maxNodes == 10000)
        #expect(limits.maxDepth == nil)
    }

    @Test func timeFactory() throws {
        let limits = SearchLimits.time(milliseconds: 250)
        #expect(limits.maxMilliseconds == 250)
        #expect(limits.maxDepth == nil)
    }

    @Test func combinedLimits() throws {
        let limits = SearchLimits(maxDepth: 8, maxNodes: 100000, maxMilliseconds: 1000)
        #expect(limits.maxDepth == 8)
        #expect(limits.maxNodes == 100000)
        #expect(limits.maxMilliseconds == 1000)
    }

    @Test func searchControlBegins() throws {
        let control = SearchControl()
        #expect(!control.isStopRequested)
    }

    @Test func searchControlStop() throws {
        let control = SearchControl()
        control.requestStop()
        #expect(control.isStopRequested)
    }

    @Test func searchControlReset() throws {
        let control = SearchControl()
        control.requestStop()
        #expect(control.isStopRequested)
        control.reset()
        #expect(!control.isStopRequested)
    }
}
