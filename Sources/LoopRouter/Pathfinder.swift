import Foundation

/// A* over the road graph with a penalty for re-using segments already ridden.
struct Pathfinder {
    let graph: RoadGraph

    /// Returns the edge indices of the cheapest path, or nil if unreachable.
    ///
    /// `cost` receives the edge plus the distance and climbing done since `source`
    /// along the best path found so far, so time-dependent costs (wind, rain,
    /// traffic) can be evaluated at the moment the rider gets there.
    func path(from source: Int, to target: Int,
              usedSegments: Set<Int>, reusePenalty: (RoadEdge) -> Double,
              cost: (_ edge: RoadEdge, _ travelled: Double, _ climbed: Double) -> Double) -> [Int]? {
        if source == target { return [] }
        let n = graph.nodes.count
        let goal = graph.nodes[target].coordinate
        var g = [Double](repeating: .infinity, count: n)
        var travelled = [Double](repeating: 0, count: n)
        var climbed = [Double](repeating: 0, count: n)
        var via = [Int](repeating: -1, count: n)
        var closed = [Bool](repeating: false, count: n)
        var open = MinHeap()

        func h(_ i: Int) -> Double {
            Geo.distance(graph.nodes[i].coordinate, goal) * CostModel.minMultiplier
        }

        g[source] = 0
        open.push(h(source), source)
        while let (_, u) = open.pop() {
            if u == target { break }
            if closed[u] { continue }
            closed[u] = true
            for ei in graph.outgoing[u] {
                let e = graph.edges[ei]
                if closed[e.to] { continue }
                var c = cost(e, travelled[u], climbed[u])
                if usedSegments.contains(e.segmentID) { c *= 1 + reusePenalty(e) }
                let cand = g[u] + c
                if cand < g[e.to] {
                    g[e.to] = cand
                    via[e.to] = ei
                    travelled[e.to] = travelled[u] + e.length
                    climbed[e.to] = climbed[u] + e.ascent
                    open.push(cand + h(e.to), e.to)
                }
            }
        }
        guard via[target] != -1 else { return nil }
        var result: [Int] = []
        var cur = target
        while cur != source {
            let ei = via[cur]
            result.append(ei)
            cur = graph.edges[ei].from
        }
        return result.reversed()
    }

    /// Cheapest paths from `source` to every node reachable within `maxDistance` metres of
    /// riding (Dijkstra). `via[n]` is the last edge on the cheapest path to `n`, -1 if none.
    func tree(from source: Int, maxDistance: Double,
              cost: (_ edge: RoadEdge, _ travelled: Double, _ climbed: Double) -> Double)
        -> (cost: [Double], travelled: [Double], via: [Int]) {
        let n = graph.nodes.count
        var g = [Double](repeating: .infinity, count: n)
        var travelled = [Double](repeating: 0, count: n)
        var climbed = [Double](repeating: 0, count: n)
        var via = [Int](repeating: -1, count: n)
        var closed = [Bool](repeating: false, count: n)
        var open = MinHeap()
        g[source] = 0
        open.push(0, source)
        while let (_, u) = open.pop() {
            if closed[u] { continue }
            closed[u] = true
            guard travelled[u] <= maxDistance else { continue }
            for ei in graph.outgoing[u] {
                let e = graph.edges[ei]
                if closed[e.to] { continue }
                let cand = g[u] + cost(e, travelled[u], climbed[u])
                if cand < g[e.to] {
                    g[e.to] = cand
                    via[e.to] = ei
                    travelled[e.to] = travelled[u] + e.length
                    climbed[e.to] = climbed[u] + e.ascent
                    open.push(cand, e.to)
                }
            }
        }
        return (g, travelled, via)
    }

    /// The edges from the tree's source to `target`, or nil if `target` wasn't reached.
    func path(to target: Int, via: [Int], from source: Int) -> [Int]? {
        var result: [Int] = []
        var cur = target
        while cur != source {
            let ei = via[cur]
            guard ei >= 0 else { return nil }
            result.append(ei)
            cur = graph.edges[ei].from
        }
        return result.reversed()
    }
}

/// Binary min-heap of (priority, node).
struct MinHeap {
    private var items: [(Double, Int)] = []

    mutating func push(_ p: Double, _ v: Int) {
        items.append((p, v))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            if items[parent].0 <= items[i].0 { break }
            items.swapAt(parent, i)
            i = parent
        }
    }

    mutating func pop() -> (Double, Int)? {
        guard !items.isEmpty else { return nil }
        let top = items[0]
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count && items[l].0 < items[m].0 { m = l }
                if r < items.count && items[r].0 < items[m].0 { m = r }
                if m == i { break }
                items.swapAt(i, m)
                i = m
            }
        }
        return top
    }
}
