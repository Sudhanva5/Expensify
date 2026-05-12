import Foundation
import UIKit

/// Opens Apple Maps to a given lat/lng. Uses the `http://maps.apple.com`
/// URL scheme so iOS reliably hands it to the system Maps app. Optional
/// `label` shows as a pin title in Maps.
enum MapsLinker {
    static func open(latitude: Double, longitude: Double, label: String? = nil) {
        var components = URLComponents(string: "http://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "q", value: label ?? "\(latitude),\(longitude)"),
        ]
        guard let url = components?.url else { return }
        UIApplication.shared.open(url)
    }
}
