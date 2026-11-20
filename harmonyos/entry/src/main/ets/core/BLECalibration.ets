import { JsonValue } from './JsonValue';
import { LeapBLEConfiguration, BLEUnlockDistance } from './BLEProtocol';
import { LeapError } from './LeapError';

export class BLECalibration {
  readonly multipleAnchors: boolean;
  readonly defaults: LeapBLEConfiguration;
  readonly selectedDistance: BLEUnlockDistance;

  constructor(defaults: LeapBLEConfiguration, selectedDistance: BLEUnlockDistance, multipleAnchors: boolean = false) {
    this.multipleAnchors = multipleAnchors;
    this.defaults = defaults;
    this.selectedDistance = selectedDistance;
  }

  static fromJson(json: JsonValue, multipleAnchors: boolean = false): BLECalibration {
    const node = json.get('data') ?? json;
    const defaults = BLECalibration.parse(node.get(multipleAnchors ? 'multipleAnchorPointParams' : 'anchorPointParams')?.stringValue ?? '');
    if (defaults === null) { throw LeapError.decode('车辆距离标定数据无效'); }
    const custom = BLECalibration.parse(node.get(multipleAnchors ? 'multipleAnchorAutonomyParams' : 'autonomyParams')?.stringValue ?? '');
    const selection = custom?.unlockCalibration === 4 ? BLEUnlockDistance.Near
      : (custom?.unlockCalibration === 7 ? BLEUnlockDistance.Far : BLEUnlockDistance.Standard);
    return new BLECalibration(defaults, selection, multipleAnchors);
  }

  static parse(text: string): LeapBLEConfiguration | null {
    const fields = text.split(';');
    if (fields.length < 4 || fields.slice(0, 4).some((s: string) => s.trim().length === 0)) { return null; }
    const values = fields.slice(0, 4).map((s: string) => Number(s));
    if (values.some((n: number) => !Number.isFinite(n))
      || ![values[0], values[2], values[3]].every((n: number) => Number.isInteger(n) && n >= 0 && n <= 255)
      || values[1] <= 0 || values[1] * 100 > 65535) { return null; }
    return new LeapBLEConfiguration(values[0], Math.round(values[1] * 100), values[2], values[3],
      true, false, false, false);
  }

  applying(configuration: LeapBLEConfiguration): LeapBLEConfiguration {
    const selection = configuration.distanceSelection < 0 ? this.selectedDistance : configuration.unlockDistance;
    return new LeapBLEConfiguration(this.defaults.distanceCalibration, this.defaults.coefficientHundredths,
      this.defaults.unlockCalibration, this.defaults.lockCalibration,
      configuration.isEnabled, configuration.autoLockEnabled, configuration.autoUnlockEnabled,
      configuration.supportsButton, selection, this.defaults.unlockCalibration, this.multipleAnchors).withUnlockDistance(selection);
  }
}
