import Foundation

// Native port of analytics/dialhack_analytics/model.py: clustering, anomaly detection, classifier.
// Deterministic (seeded). Algorithms mirror the Python version; the classifier is k-nearest-neighbours
// instead of a random forest (no ML library here), evaluated the same way.

struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 { // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Linear {
    static func dist2(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } }

    /// Column-wise z-scores (population std, like sklearn's StandardScaler; constant columns → 0).
    static func standardize(_ X: [[Double]]) -> [[Double]] {
        guard let d = X.first?.count, !X.isEmpty else { return X }
        let n = Double(X.count)
        var mean = [Double](repeating: 0, count: d), sd = mean
        for r in X { for j in 0..<d { mean[j] += r[j] / n } }
        for r in X { for j in 0..<d { sd[j] += (r[j] - mean[j]) * (r[j] - mean[j]) / n } }
        sd = sd.map { $0.squareRoot() }
        return X.map { r in (0..<d).map { j in sd[j] > 1e-12 ? (r[j] - mean[j]) / sd[j] : 0 } }
    }
}

enum KMeans {
    struct Result { let k: Int; let labels: [Int]; let silhouette: Double }

    static func fit(_ X: [[Double]], k: Int, seed: UInt64, restarts: Int = 10, iterations: Int = 100) -> (labels: [Int], inertia: Double) {
        var rng = SeededRNG(seed: seed)
        var best: ([Int], Double) = ([], .infinity)
        for _ in 0..<restarts {
            // k-means++ init
            var centers = [X[Int.random(in: 0..<X.count, using: &rng)]]
            while centers.count < k {
                let d = X.map { x in centers.map { Linear.dist2(x, $0) }.min()! }
                let total = d.reduce(0, +)
                guard total > 0 else { centers.append(X[Int.random(in: 0..<X.count, using: &rng)]); continue }
                var r = Double.random(in: 0..<total, using: &rng)
                var idx = 0
                for (i, v) in d.enumerated() { r -= v; if r <= 0 { idx = i; break } }
                centers.append(X[idx])
            }
            var labels = [Int](repeating: 0, count: X.count)
            for _ in 0..<iterations {
                let new = X.map { x in (0..<k).min { Linear.dist2(x, centers[$0]) < Linear.dist2(x, centers[$1]) }! }
                if new == labels && centers.count == k { labels = new; break }
                labels = new
                for c in 0..<k {
                    let members = X.indices.filter { labels[$0] == c }
                    guard !members.isEmpty else { continue }
                    centers[c] = (0..<X[0].count).map { j in members.reduce(0) { $0 + X[$1][j] } / Double(members.count) }
                }
            }
            let inertia = X.indices.reduce(0) { $0 + Linear.dist2(X[$1], centers[labels[$1]]) }
            if inertia < best.1 { best = (labels, inertia) }
        }
        return best
    }

    static func silhouette(_ X: [[Double]], _ labels: [Int]) -> Double {
        let ks = Set(labels)
        guard ks.count > 1 else { return -1 }
        var total = 0.0
        for i in X.indices {
            var sums: [Int: (Double, Int)] = [:]
            for j in X.indices where j != i {
                let d = Linear.dist2(X[i], X[j]).squareRoot()
                let s = sums[labels[j]] ?? (0, 0)
                sums[labels[j]] = (s.0 + d, s.1 + 1)
            }
            guard let own = sums[labels[i]], own.1 > 0 else { continue } // singleton → 0
            let a = own.0 / Double(own.1)
            let b = sums.filter { $0.key != labels[i] }.map { $0.value.0 / Double($0.value.1) }.min() ?? 0
            total += (b - a) / max(a, b)
        }
        return total / Double(X.count)
    }

    /// Best k in 2...maxK by silhouette (like model.analyze).
    static func choose(_ X: [[Double]], maxK: Int = 6, seed: UInt64 = 0) -> Result? {
        guard X.count >= 3 else { return nil }
        var best: Result?
        for k in 2...max(2, min(maxK, X.count - 1)) {
            let (labels, _) = fit(X, k: k, seed: seed)
            guard Set(labels).count > 1 else { continue }
            let s = silhouette(X, labels)
            if best == nil || s > best!.silhouette { best = Result(k: k, labels: labels, silhouette: s) }
        }
        return best
    }
}

enum PCA {
    /// First two principal components via power iteration on the covariance matrix.
    static func project2(_ X: [[Double]]) -> [(Double, Double)] {
        guard let d = X.first?.count, X.count > 1 else { return X.map { _ in (0, 0) } }
        let n = Double(X.count)
        let mean = (0..<d).map { j in X.reduce(0) { $0 + $1[j] } / n }
        let C = X.map { r in (0..<d).map { r[$0] - mean[$0] } }
        var cov = [[Double]](repeating: [Double](repeating: 0, count: d), count: d)
        for r in C { for i in 0..<d { for j in 0..<d { cov[i][j] += r[i] * r[j] / (n - 1) } } }
        var comps: [[Double]] = []
        for _ in 0..<2 {
            var v = (0..<d).map { Double($0 + 1) }
            for _ in 0..<200 {
                var w = (0..<d).map { i in (0..<d).reduce(0) { $0 + cov[i][$1] * v[$1] } }
                for c in comps { let p = zip(w, c).reduce(0) { $0 + $1.0 * $1.1 }; w = zip(w, c).map { $0 - p * $1 } }
                let norm = w.reduce(0) { $0 + $1 * $1 }.squareRoot()
                guard norm > 1e-12 else { break }
                v = w.map { $0 / norm }
            }
            comps.append(v)
        }
        return C.map { r in (zip(r, comps[0]).reduce(0) { $0 + $1.0 * $1.1 }, zip(r, comps[1]).reduce(0) { $0 + $1.0 * $1.1 }) }
    }
}

/// Isolation forest (Liu et al.), as in sklearn with contamination="auto": anomaly when score > 0.5.
enum IsolationForest {
    private indirect enum Node { case leaf(Int), split(Int, Double, Node, Node) }

    private static func c(_ n: Int) -> Double {
        n <= 1 ? 0 : 2 * (log(Double(n - 1)) + 0.5772156649) - 2 * Double(n - 1) / Double(n)
    }

    private static func build(_ X: [[Double]], _ idx: [Int], depth: Int, limit: Int, rng: inout SeededRNG) -> Node {
        guard idx.count > 1, depth < limit else { return .leaf(idx.count) }
        let f = Int.random(in: 0..<X[0].count, using: &rng)
        let vals = idx.map { X[$0][f] }
        guard let lo = vals.min(), let hi = vals.max(), hi > lo else { return .leaf(idx.count) }
        let t = Double.random(in: lo..<hi, using: &rng)
        return .split(f, t, build(X, idx.filter { X[$0][f] < t }, depth: depth + 1, limit: limit, rng: &rng),
                      build(X, idx.filter { X[$0][f] >= t }, depth: depth + 1, limit: limit, rng: &rng))
    }

    private static func path(_ x: [Double], _ node: Node, _ depth: Int) -> Double {
        switch node {
        case let .leaf(n): return Double(depth) + c(n)
        case let .split(f, t, l, r): return path(x, x[f] < t ? l : r, depth + 1)
        }
    }

    static func scores(_ X: [[Double]], trees: Int = 200, sample: Int = 256, seed: UInt64 = 0) -> [Double] {
        var rng = SeededRNG(seed: seed)
        let m = min(sample, X.count)
        let limit = Int(ceil(log2(Double(max(m, 2)))))
        let forest = (0..<trees).map { _ -> Node in
            let idx = Array(X.indices.shuffled(using: &rng).prefix(m))
            return build(X, idx, depth: 0, limit: limit, rng: &rng)
        }
        return X.map { x in pow(2, -(forest.map { path(x, $0, 0) }.reduce(0, +) / Double(trees)) / c(m)) }
    }
}

// MARK: - classifier

struct ClassifierFold: Identifiable {
    let id: Int
    let trainWindows: Int, testWindows: Int
    let trainUntil: Date, testFrom: Date
    let modelAccuracy: Double, baselineAccuracy: Double
    let modelBalanced: Double, baselineBalanced: Double
    let baselinePredicts: String
}

struct ClassifierReport {
    var ok = false
    var reason = ""
    var labeled = 0
    var classCounts: [String: Int] = [:]
    var classesUsed: [String] = []
    var folds: [ClassifierFold] = []

    var modelAccuracy: Double { folds.map(\.modelAccuracy).mean }
    var baselineAccuracy: Double { folds.map(\.baselineAccuracy).mean }
    var modelBalanced: Double { folds.map(\.modelBalanced).mean }
    var baselineBalanced: Double { folds.map(\.baselineBalanced).mean }
    var beatsBaseline: Bool { modelBalanced > baselineBalanced }
}

extension Array where Element == Double {
    var mean: Double { isEmpty ? .nan : reduce(0, +) / Double(count) }
}

enum Classifier {
    static let minLabeled = 30
    static let minPerClass = 5
    static let maxFolds = 5
    static let k = 5

    static func knn(train: [[Double]], labels: [String], _ x: [Double]) -> String {
        let nearest = train.indices.sorted { Linear.dist2(train[$0], x) < Linear.dist2(train[$1], x) }.prefix(k)
        var votes: [String: Double] = [:]
        for i in nearest { votes[labels[i], default: 0] += 1 / (Linear.dist2(train[i], x).squareRoot() + 1e-6) }
        return votes.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }!.key
    }

    static func accuracy(_ y: [String], _ p: [String]) -> Double { Double(zip(y, p).filter { $0 == $1 }.count) / Double(y.count) }

    /// Mean recall over the classes present in y (sklearn balanced_accuracy_score).
    static func balanced(_ y: [String], _ p: [String]) -> Double {
        Set(y).map { c in
            let idx = y.indices.filter { y[$0] == c }
            return Double(idx.filter { p[$0] == c }.count) / Double(idx.count)
        }.mean
    }

    /// Same protocol as model.classify: sklearn TimeSeriesSplit(n_splits, gap=1) folds, majority baseline,
    /// "not enough data" below the minimums. Fills `predicted` on unlabeled windows.
    static func evaluate(_ windows: inout [FidgetWindow]) -> ClassifierReport {
        let labeled = windows.indices.filter { windows[$0].label != nil }.sorted { windows[$0].start < windows[$1].start }
        var rep = ClassifierReport()
        rep.labeled = labeled.count
        rep.classCounts = Dictionary(grouping: labeled.map { windows[$0].label! }, by: { $0 }).mapValues(\.count)
        let usable = rep.classCounts.filter { $0.value >= minPerClass }.map(\.key).sorted()
        if labeled.count < minLabeled || usable.count < 2 {
            var need: [String] = []
            if labeled.count < minLabeled { need.append("\(minLabeled) labeled windows (have \(labeled.count))") }
            if usable.count < 2 { need.append("at least 2 labels with ≥ \(minPerClass) windows each (have \(usable.count))") }
            rep.reason = "Not enough data: need " + need.joined(separator: " and ") + "."
            return rep
        }

        let rows = labeled.filter { usable.contains(windows[$0].label!) }
        let Z = Linear.standardize(windows.map(\.featureVector))   // scale on all windows (unsupervised)
        let X = rows.map { Z[$0] }, y = rows.map { windows[$0].label! }, t = rows.map { windows[$0].start }
        let n = rows.count
        let splits = Swift.min(maxFolds, Swift.max(2, n / 10))
        let testSize = n / (splits + 1)
        var fold = 0
        for start in stride(from: n - splits * testSize, to: n, by: testSize) {
            fold += 1
            let trainEnd = start - 1 // gap = 1
            guard trainEnd > 0 else { continue }
            let tr = Array(0..<trainEnd), te = Array(start..<min(start + testSize, n))
            let ytr = tr.map { y[$0] }
            guard Set(ytr).count >= 2, !te.isEmpty else { continue }
            let majority = Dictionary(grouping: ytr, by: { $0 }).max { $0.value.count < $1.value.count || ($0.value.count == $1.value.count && $0.key > $1.key) }!.key
            let yte = te.map { y[$0] }
            let pm = te.map { knn(train: tr.map { X[$0] }, labels: ytr, X[$0]) }
            let pb = te.map { _ in majority }
            rep.folds.append(ClassifierFold(id: fold, trainWindows: tr.count, testWindows: te.count,
                                            trainUntil: t[tr.last!], testFrom: t[te.first!],
                                            modelAccuracy: accuracy(yte, pm), baselineAccuracy: accuracy(yte, pb),
                                            modelBalanced: balanced(yte, pm), baselineBalanced: balanced(yte, pb),
                                            baselinePredicts: majority))
        }
        guard !rep.folds.isEmpty else {
            rep.reason = "Not enough data: no time-ordered fold had ≥ 2 labels in its training part yet."
            return rep
        }
        rep.ok = true
        rep.classesUsed = usable
        let dropped = rep.classCounts.keys.filter { !usable.contains($0) }.sorted()
        if !dropped.isEmpty { rep.reason = "Left out (fewer than \(minPerClass) windows): \(dropped.joined(separator: ", "))." }
        for i in windows.indices where windows[i].label == nil {
            windows[i].predicted = knn(train: X, labels: y, Z[i])
        }
        return rep
    }
}

// MARK: - the whole analysis

struct InsightsResult {
    var windows: [FidgetWindow] = []
    var k: Int?
    var silhouette: Double?
    var classifier = ClassifierReport()
    var notes: [String] = []
    var events = 0

    var active: [FidgetWindow] { windows.filter { !$0.likelyStray } }
}

enum Insights {
    static let minToCluster = 6
    static let minForAnomalies = 8

    static func analyze(events: [DialRecord], labelEvents: [LabelEventRecord], hand: [HandLabel], minutes: Double = 5,
                        includeStray: Bool = false, calendar: Calendar = .current) -> InsightsResult {
        var r = InsightsResult()
        r.events = events.count
        let votes = LabelSources.votes(labelEvents, hand, minutes: minutes)
        var w = Fidget.windows(events, minutes: minutes, include: Array(Set(votes.map(\.window))), calendar: calendar)
        LabelSources.assign(&w, votes)
        guard !w.isEmpty else {
            r.notes.append("No dial events yet.")
            r.classifier.reason = "No labeled windows yet."
            return r
        }
        let idx = w.indices.filter { includeStray || !w[$0].likelyStray }
        let strays = w.count - idx.count
        if strays > 0 { r.notes.append("\(strays) likely-stray windows (≤ 2 events) left out of clustering.") }

        if idx.count >= minToCluster {
            let X = Linear.standardize(idx.map { w[$0].featureVector })
            if let km = KMeans.choose(X) {
                r.k = km.k
                r.silhouette = km.silhouette
                for (n, i) in idx.enumerated() { w[i].cluster = km.labels[n] }
            }
            for (n, p) in PCA.project2(X).enumerated() { w[idx[n]].pca = p }
            if idx.count >= minForAnomalies {
                let s = IsolationForest.scores(X)
                let rates = idx.map { w[$0].rotationsPerMin }.sorted()
                let median = rates.count % 2 == 1 ? rates[rates.count / 2] : (rates[rates.count / 2 - 1] + rates[rates.count / 2]) / 2
                for (n, i) in idx.enumerated() {
                    w[i].anomalyScore = s[n]
                    w[i].restless = s[n] > 0.5 && w[i].rotationsPerMin > median
                }
            } else {
                r.notes.append("Restless detection needs \(minForAnomalies) active windows; have \(idx.count).")
            }
        } else {
            r.notes.append("Clustering needs \(minToCluster) active windows; have \(idx.count).")
        }
        r.classifier = Classifier.evaluate(&w)
        r.windows = w
        return r
    }
}
