import { LockCardContent } from '../common/LockCardContent';

@Entry
@Component
struct VehicleLockCard {
  build() {
    Stack() {
      LockCardContent({ action: 'toggleLock' })
    }
    .width('100%').height('100%')
  }
}
