import { geoLocationManager } from '@kit.LocationKit';
import { site } from '@kit.MapKit';
import { Coordinate } from '../core/LeapModels';
import { VehicleSnapshot } from './VehicleSnapshot';
import { DiagLog } from '../core/DiagLog';
import { LeapError } from '../core/LeapError';

/**
 * 把坐标换成「月亮岛小区」「桃花坞路」这类地名。App 和卡片都要用，所以放共享层。
 *
 * 走华为地图的地点服务（`site.reverseGeocode`），不是 Location Kit 的逆地理编码：
 * 车端上报的经纬度是 GCJ-02，和地图数据同一套坐标系，直接送进去就是对的；
 * Location Kit 那一路要的是 WGS-84，喂 GCJ-02 进去在国内会往东北偏出去几百米，
 * 表现就是「图上的点是对的，底下那行地址却是隔壁那条路」。
 *
 * 我们只是把车报上来的坐标换成地名，从不读手机自己的位置，所以不需要定位权限。
 * 解析不出来就返回 null——界面上宁可只说「车辆位置」，也不要退回去显示经纬度。
 */
export class LocationNaming {
  static async resolve(coordinate: Coordinate): Promise<string | null> {
    const fromMap = await LocationNaming.resolveByMapKit(coordinate);
    if (fromMap !== null) {
      return fromMap;
    }
    // 地图的地点服务没开通、没配额或恰好零结果时的兜底。
    // 注意这一路的结果本身就带着 GCJ-02 当 WGS-84 用的几百米偏差，
    // 只是「偏一条街的地名」仍然比「什么都不显示」有用一点。
    return LocationNaming.resolveByLocationKit(coordinate);
  }

  /** 华为地图地点服务。坐标系与车端上报的一致（GCJ-02），不需要任何转换。 */
  private static async resolveByMapKit(coordinate: Coordinate): Promise<string | null> {
    try {
      const result = await site.reverseGeocode({
        location: { latitude: coordinate.latitude, longitude: coordinate.longitude },
        language: 'zh',
        // 不开扩展就只有行政区划，路名、小区名、POI 全都拿不到。
        isExtension: true,
        isNearbyAoi: true
      });
      return LocationNaming.nameOf(result);
    } catch (e) {
      DiagLog.note(`[map] 地点服务反解析失败：${LeapError.messageOf(e as object)}`);
      return null;
    }
  }

  /** 门牌离得再远也会被返回，超过这个距离就不能拿来说「车在这」。 */
  private static readonly streetNumberLimit = 50;

  /**
   * 从反解析结果里挑一个最像「车停在哪」的名字。
   *
   * 小区/园区（AOI）排在最前：车停在院子里时，「月亮岛小区」比任何路名都说明问题。
   * AOI 取面积最小的那个——同一个点会同时命中「月亮岛」景区、「皖西学院」和
   * 「月亮岛小区」，服务按距离排序，大范围的反而排在前面，只有面积能区分出谁更具体。
   */
  private static nameOf(result: site.ReverseGeocodeResult): string | null {
    const address = result.addressComponent;
    const aoi = LocationNaming.smallestAoi(result.aois);
    if (aoi !== null) {
      return LocationNaming.capped(aoi, address);
    }

    // 门牌比裸路名精确，但实测会给出 86 米外另一条街的门牌，所以要卡距离。
    const street = address.streetNumber;
    if (street !== undefined
      && (street.distance === undefined || street.distance <= LocationNaming.streetNumberLimit)) {
      const streetName = LocationNaming.text(street.streetName);
      if (streetName !== null) {
        const number = LocationNaming.text(street.streetNumber);
        return LocationNaming.capped(number !== null ? `${streetName}${number}` : streetName, address);
      }
    }

    const road = LocationNaming.nearestName(result.roads);
    if (road !== null) {
      return LocationNaming.capped(road, address);
    }

    const poi = LocationNaming.nearestName(result.pois);
    if (poi !== null) {
      return LocationNaming.capped(poi, address);
    }

    // 行政区划字段实测经常整片是空的，只有这一条完整描述总有值。
    const described = LocationNaming.text(result.addressDescription);
    return described === null ? null : LocationNaming.capped(described, address);
  }

  /** 地名超过这个字数就开始剥行政区划前缀。首页那行和卡片上都只有一行的位置。 */
  private static readonly nameLimit = 12;

  /**
   * 名字太长时，从头上一层层剥掉行政区划（省、市、区、街道）。
   *
   * 只剥前缀、不硬截断：截断会把「枫丹壹号」切成「枫丹壹」，读起来像另一个地方；
   * 剥掉的省市区则本来就是这台车的主人最不需要被告知的部分。剥完还是长，那就让它长——
   * 说不完整的地名不如说完。
   */
  private static capped(name: string, address: site.AddressComponent | undefined): string {
    if (name.length <= LocationNaming.nameLimit || address === undefined) {
      return name;
    }
    const prefixes: Array<string | undefined> = [
      address.adminLevel1, address.adminLevel2, address.adminLevel3,
      address.locality, address.subLocality1
    ];
    let trimmed = name;
    for (let i = 0; i < prefixes.length; i++) {
      const part = prefixes[i];
      if (part === undefined || part.length === 0 || !trimmed.startsWith(part)
        || trimmed.length <= part.length) {
        continue;
      }
      trimmed = trimmed.substring(part.length);
      if (trimmed.length <= LocationNaming.nameLimit) {
        break;
      }
    }
    return trimmed;
  }

  private static smallestAoi(aois: Array<site.Aoi> | undefined): string | null {
    if (aois === undefined) {
      return null;
    }
    let best: string | null = null;
    let bestArea = Number.MAX_SAFE_INTEGER;
    for (let i = 0; i < aois.length; i++) {
      const name = LocationNaming.text(aois[i].name);
      if (name === null) {
        continue;
      }
      // 没给面积的排在所有给了面积的后面，但仍好过一个都不选。
      const area = aois[i].area ?? Number.MAX_SAFE_INTEGER;
      if (best === null || area < bestArea) {
        best = name;
        bestArea = area;
      }
    }
    return best;
  }

  /** 一组带距离的地点里离车最近的那个名字。服务本来就按距离排序，这里只是不依赖它。 */
  private static nearestName(items: Array<site.Road> | Array<site.ReverseGeocodePoi>
    | undefined): string | null {
    if (items === undefined) {
      return null;
    }
    let best: string | null = null;
    let bestDistance = Number.MAX_SAFE_INTEGER;
    for (let i = 0; i < items.length; i++) {
      const name = LocationNaming.text(items[i].name);
      if (name === null) {
        continue;
      }
      const distance = items[i].distance ?? Number.MAX_SAFE_INTEGER;
      if (best === null || distance < bestDistance) {
        best = name;
        bestDistance = distance;
      }
    }
    return best;
  }

  private static text(value: string | undefined): string | null {
    return value !== undefined && value.length > 0 ? value : null;
  }

  /** Location Kit 的逆地理编码。它要的是 WGS-84，只当兜底用。 */
  private static async resolveByLocationKit(coordinate: Coordinate): Promise<string | null> {
    try {
      if (!geoLocationManager.isGeocoderAvailable()) {
        return null;
      }
      const addresses = await geoLocationManager.getAddressesFromLocation({
        latitude: coordinate.latitude,
        longitude: coordinate.longitude,
        maxItems: 1,
        locale: 'zh'
      });
      if (addresses.length === 0) {
        return null;
      }
      const address = addresses[0];
      const road = address.roadName;
      if (road !== undefined && road.length > 0) {
        const sub = address.subRoadName;
        return sub !== undefined && sub.length > 0 ? `${road}${sub}` : road;
      }
      const place = address.placeName;
      if (place !== undefined && place.length > 0) {
        return place;
      }
      const subLocality = address.subLocality;
      if (subLocality !== undefined && subLocality.length > 0) {
        return subLocality;
      }
      const locality = address.locality;
      return locality !== undefined && locality.length > 0 ? locality : null;
    } catch (e) {
      return null;
    }
  }

  /**
   * 车基本没动的话就沿用上次解析出的名字，省一次反解析。
   * 0.0005° 在这个纬度上大约是 50 米，小于这个距离没必要重新解析。
   */
  static async nameReusing(coordinate: Coordinate,
    previous: VehicleSnapshot | null): Promise<string | null> {
    if (previous !== null && previous.locationName !== null && previous.locationName.length > 0
      && previous.latitude !== null && previous.longitude !== null
      && Math.abs(previous.latitude - coordinate.latitude) < 0.0005
      && Math.abs(previous.longitude - coordinate.longitude) < 0.0005) {
      return previous.locationName;
    }
    return LocationNaming.resolve(coordinate);
  }
}
