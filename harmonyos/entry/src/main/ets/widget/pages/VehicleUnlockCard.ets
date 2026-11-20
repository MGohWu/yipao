import { LockCardContent } from '../common/LockCardContent';

@Entry
@Component
struct VehicleUnlockCard {
  build() {
    Stack() {
      LockCardContent({ action: 'unlock' })
    }
    .width('100%').height('100%')
  }
}
