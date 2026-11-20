import { LockCardContent } from '../common/LockCardContent';

@Entry
@Component
struct VehicleLockOnlyCard {
  build() {
    Stack() {
      LockCardContent({ action: 'lock' })
    }
    .width('100%').height('100%')
  }
}
