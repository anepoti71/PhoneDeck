import Foundation

public enum Versions {
    /// Compares dotted numeric versions ("11.51.0" > "11.50.3"); a part's non-numeric suffix is
    /// ignored ("11.51.0rc1" counts as 11.51.0) and missing parts count as 0 ("11.51" == "11.51.0").
    public static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
