import Foundation

extension LoopRoute {
    /// GeoJSON Feature (LineString with [lon, lat, ele] along the full shape) plus metrics
    /// as properties.
    public func geoJSONFeature() -> [String: Any] {
        let coords: [[Double]] = zip(displayCoordinates, displayElevations).map {
            [($0.longitude * 1e6).rounded() / 1e6, ($0.latitude * 1e6).rounded() / 1e6, ($1 * 10).rounded() / 10]
        }
        let m = metrics
        return [
            "type": "Feature",
            "geometry": ["type": "LineString", "coordinates": coords],
            "properties": [
                "id": id,
                "distance_km": (m.distance / 100).rounded() / 10,
                "ascent_m": m.ascent.rounded(),
                "descent_m": m.descent.rounded(),
                "max_grade_pct": (m.maxGrade * 1000).rounded() / 10,
                "duration_min": (m.estimatedDuration / 60).rounded(),
                "traffic_exposure": (m.trafficExposure * 100).rounded() / 100,
                "busy_road_share": (m.busyRoadShare * 100).rounded() / 100,
                "cycleway_share": (m.cyclewayShare * 100).rounded() / 100,
                "urban_share": (m.urbanShare * 100).rounded() / 100,
                "lf_share": (m.lfShare * 100).rounded() / 100,
                "eurovelo_share": (m.euroVeloShare * 100).rounded() / 100,
                "traffic_signals": m.trafficSignals.rounded(),
                "town_exit_km": (m.townExitDistance / 100).rounded() / 10,
                "town_return_km": (m.townReturnDistance / 100).rounded() / 10,
                "unpaved_share": (m.unpavedShare * 100).rounded() / 100,
                "headwind_first_half_ms": (m.headwindFirstHalf * 10).rounded() / 10,
                "headwind_second_half_ms": (m.headwindSecondHalf * 10).rounded() / 10,
                "headwind_exposure_ms": (m.headwindExposure * 10).rounded() / 10,
                "strong_headwind_share": (m.strongHeadwindShare * 100).rounded() / 100,
                "wet_share": (m.wetShare * 100).rounded() / 100,
                "expected_rain_mm": (m.expectedRainMm * 10).rounded() / 10,
                "wind_time_loss_min": (m.windTimeLoss / 6).rounded() / 10,
                "wind_effort_min": (m.windEffort / 6).rounded() / 10,
                "rain_effort_min": (m.rainEffort / 6).rounded() / 10,
                "reused_share": (m.reusedShare * 100).rounded() / 100,
                "score": (score.total * 100).rounded() / 100,
                "knooppunten": knooppunten,
                "access_distance_m": accessDistance.rounded(),
            ] as [String: Any],
        ]
    }

    /// GPX with one waypoint per knooppunt (named by its number) and the full shape as track.
    public func gpx(name: String? = nil) -> String {
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="LoopRouter" xmlns="http://www.topografix.com/GPX/1/1">

        """
        var marked = Set<Int64>()
        for j in junctions where marked.insert(j.junctionID).inserted {
            let number = j.number.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            s += String(format: "  <wpt lat=\"%.6f\" lon=\"%.6f\">", j.coordinate.latitude, j.coordinate.longitude)
                + "<name>\(number)</name><type>knooppunt</type></wpt>\n"
        }
        s += """
          <trk><name>\(name ?? "Loop \(id)")</name>\(knooppunten.isEmpty ? "" : "<desc>Knooppunten: \(knooppunten.joined(separator: " → "))</desc>")<trkseg>

        """
        for (c, e) in zip(displayCoordinates, displayElevations) {
            s += String(format: "      <trkpt lat=\"%.6f\" lon=\"%.6f\"><ele>%.1f</ele></trkpt>\n", c.latitude, c.longitude, e)
        }
        s += "  </trkseg></trk>\n</gpx>\n"
        return s
    }
}

extension LoopPlan {
    public func geoJSON() throws -> Data {
        let fc: [String: Any] = ["type": "FeatureCollection", "features": routes.map { $0.geoJSONFeature() }]
        return try JSONSerialization.data(withJSONObject: fc, options: [.prettyPrinted, .sortedKeys])
    }
}
