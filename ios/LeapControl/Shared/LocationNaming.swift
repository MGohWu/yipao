import CoreLocation
import MapKit

/// 把坐标换成"昌建融创枫丹壹号""桃花坞路"这类地名。App 和卡片都要用，所以放共享层。
/// 解析不出来就返回 nil——界面上宁可只说"车辆位置"，也不要退回去显示经纬度。
///
/// **入参一律是车端原样的 GCJ-02，这里不转**：苹果的反地理编码在大陆和地图同一套口径，
/// 收的就是 GCJ-02（见 `CoordinateTransform`）。转一次的话解析出来的是隔壁街的地址，
/// 而这种错读起来完全像是「反解析不准」，查不到坐标系上去。
enum LocationNaming {
    /// 地名超过这个字数就开始剥行政区划前缀。首页那行和卡片上都只有一行的位置。
    private static let nameLimit = 12

    /// 挑一个最像「车停在哪」的名字，口径和安卓 / 鸿蒙逐档对齐：
    /// 小区、园区这类地点名排最前（车停在院子里时，「昌建融创枫丹壹号」比任何路名都说明问题），
    /// 其次是门牌和路名，整条地址只当兜底。
    ///
    /// `item.name` 在系统解不出具体地点时会退化成一整条地址，所以先按长度筛一道：
    /// 短的才是地点名，长的说明它其实就是地址，那就让位给更规整的 `shortAddress`。
    static func name(for coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location),
                  let item = try? await request.mapItems.first else { return nil }
            if let name = item.name, !name.isEmpty, name.count <= nameLimit { return name }
            if let short = item.address?.shortAddress, !short.isEmpty { return short }
            if let name = item.name, !name.isEmpty { return name }
            if let full = item.address?.fullAddress, !full.isEmpty { return full }
            return nil
        } else {
            return await legacyName(for: location)
        }
    }

    /// iOS 26 之前没有 `MKReverseGeocodingRequest`，退回 `CLGeocoder`。
    /// 它反而有 `areasOfInterest` 这个现成的园区/小区字段，档位顺序和上面一致。
    private static func legacyName(for location: CLLocation) async -> String? {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
        guard let placemark = placemarks?.first else { return nil }

        if let area = placemark.areasOfInterest?.first, !area.isEmpty { return capped(area, placemark) }

        if let street = placemark.thoroughfare, !street.isEmpty {
            if let number = placemark.subThoroughfare, !number.isEmpty {
                return street + number + "号"
            }
            return street
        }
        if let name = placemark.name, !name.isEmpty { return capped(name, placemark) }
        return placemark.subLocality ?? placemark.locality
    }

    /// 名字太长时，从头上一层层剥掉行政区划（省、市、区、街道）。
    ///
    /// 只剥前缀、不硬截断：截断会把「枫丹壹号」切成「枫丹壹」，读起来像另一个地方；
    /// 剥掉的省市区则本来就是这台车的主人最不需要被告知的部分。剥完还是长，那就让它长——
    /// 说不完整的地名不如说完。
    private static func capped(_ name: String, _ placemark: CLPlacemark) -> String {
        guard name.count > nameLimit else { return name }
        var trimmed = name
        for part in [placemark.country, placemark.administrativeArea, placemark.locality, placemark.subLocality] {
            guard let part, !part.isEmpty, trimmed.hasPrefix(part), trimmed.count > part.count else { continue }
            trimmed.removeFirst(part.count)
            if trimmed.count <= nameLimit { break }
        }
        return trimmed
    }

    /// 车基本没动的话就沿用上次解析出的名字，省一次反解析。
    /// 0.0005° 在这个纬度上大约是 50 米，小于这个距离没必要重新解析。
    ///
    /// 比的是两个 GCJ-02（快照里存的也是车端原样），同坐标系。
    static func name(
        for coordinate: CLLocationCoordinate2D,
        reusing previous: VehicleSnapshot?
    ) async -> String? {
        if let previous,
           let name = previous.locationName, !name.isEmpty,
           let latitude = previous.latitude, let longitude = previous.longitude,
           abs(latitude - coordinate.latitude) < 0.0005,
           abs(longitude - coordinate.longitude) < 0.0005 {
            return name
        }
        return await name(for: coordinate)
    }
}
