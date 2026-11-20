import SwiftUI
import UIKit

struct BluetoothKeySettingsView: View {
    @Environment(VehicleStore.self) private var store
    @State private var showRemoveConfirmation = false
    @State private var distanceSaving = false

    private var controller: BLEVehicleController { store.bleController }

    var body: some View {
        @Bindable var controller = controller

        List {
            Section { NavigationLink("蓝牙诊断") { BLEDiagnosticsView() } }
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(controller.runtimeState.label)
                        if let detail = controller.runtimeState.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: runtimeSymbol)
                        .foregroundStyle(runtimeTint)
                }

                if controller.binding == nil {
                    NavigationLink {
                        BLEPairingView()
                    } label: {
                        Label("搜索并绑定车辆", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
            } header: {
                Text("状态")
            } footer: {
                Text("用户强制结束 App 或关闭系统蓝牙后，无感钥匙需要重新打开 App 才能恢复。")
            }

            if let binding = controller.binding {
                Section {
                    Toggle(
                        isOn: Binding(
                            get: { controller.isBluetoothControlEnabled },
                            set: { store.setBluetoothControlEnabled($0) }
                        )
                    ) {
                        Label("蓝牙控车", systemImage: "key.radiowaves.forward.fill")
                    }
                    .tint(LeapStyle.accent)

                    Toggle(
                        isOn: Binding(
                            get: { controller.autoUnlockEnabled },
                            set: { store.setPassiveAutoUnlock($0) }
                        )
                    ) {
                        Label("无感解锁", systemImage: "lock.open.fill")
                    }
                    .tint(LeapStyle.accent)
                    .disabled(!controller.isBluetoothControlEnabled)

                    Toggle(
                        isOn: Binding(
                            get: { controller.autoLockEnabled },
                            set: { store.setPassiveAutoLock($0) }
                        )
                    ) {
                        Label("离车自动闭锁", systemImage: "lock.fill")
                    }
                    .tint(LeapStyle.accent)
                    .disabled(!controller.isBluetoothControlEnabled)

                    Picker("解锁距离", selection: Binding(
                        get: { controller.binding?.configuration.unlockDistance ?? .standard },
                        set: { distance in
                            distanceSaving = true
                            Task {
                                await store.setBLEUnlockDistance(distance)
                                distanceSaving = false
                            }
                        }
                    )) {
                        ForEach(BLEUnlockDistance.allCases, id: \.self) { distance in
                            Text(distance.label).tag(distance)
                        }
                    }
                    .disabled(!controller.isBluetoothControlEnabled || distanceSaving)

                    LabeledContent("设置同步", value: syncStateText)
                    LabeledContent("快速重连", value: controller.reconnectTokenAvailable ? "已就绪" : "等待首次认证")
                    if controller.isPassiveEntryEnabled {
                        LabeledContent("靠近唤醒", value: controller.proximityWakeState.label)
                        if controller.proximityWakeState == .needsAlwaysAuthorization {
                            Button {
                                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                                UIApplication.shared.open(url)
                            } label: {
                                Label("允许后台靠近唤醒", systemImage: "location.fill")
                            }
                        }
                    }
                } header: {
                    Text("车辆钥匙")
                } footer: {
                    Text("距离调整用于无感解锁，靠近车辆并连接后生效。锁屏或后台靠近唤醒需要将定位权限设为“始终”；App 只监测车辆 Beacon 区域，不持续定位或上传位置。实际距离会受手机、携带位置和周围环境影响。")
                }

                Section {
                    LabeledContent("车辆", value: masked(binding.peripheralIdentifier))
                    LabeledContent("证书", value: binding.certificateFingerprint)
                    if let date = binding.lastVerifiedAt {
                        LabeledContent("最近验证") {
                            Text(date, format: .relative(presentation: .named))
                        }
                    }

                    NavigationLink {
                        BLEPairingView()
                    } label: {
                        Label("重新绑定", systemImage: "arrow.triangle.2.circlepath")
                    }

                    Button(role: .destructive) {
                        showRemoveConfirmation = true
                    } label: {
                        Label("移除蓝牙钥匙", systemImage: "key.slash")
                    }
                    .confirmationDialog(
                        "移除蓝牙钥匙？",
                        isPresented: $showRemoveConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("移除", role: .destructive) {
                            store.removeBluetoothBinding()
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("App 会先同步关闭车辆端无感设置；车辆不在附近时会保留为待同步。")
                    }
                } header: {
                    Text("绑定")
                }
            }
        }
        .navigationTitle("蓝牙钥匙")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background { LeapBackground(tint: LeapStyle.cool) }
        .onAppear {
            store.refreshBluetoothRuntime()
            controller.requestProximityWakeAuthorization()
        }
        .task(id: controller.binding?.vin) { await store.refreshBLECalibration() }
    }

    private var syncStateText: String {
        switch controller.configurationSyncState {
        case .synced: return "已同步"
        case .pending: return "等待车辆"
        case .pendingDisable: return "等待同步关闭"
        case nil: return "未绑定"
        }
    }

    private var runtimeSymbol: String {
        switch controller.runtimeState {
        case .ready: return "checkmark.circle.fill"
        case .waitingForBluetooth, .needsAttention: return "exclamationmark.triangle.fill"
        case .disabled: return "power"
        case .unbound: return "link.badge.plus"
        case .scanning: return "antenna.radiowaves.left.and.right"
        case .connecting, .authenticating, .syncingConfiguration, .recovering:
            return "arrow.triangle.2.circlepath"
        }
    }

    private var runtimeTint: Color {
        switch controller.runtimeState {
        case .ready: return LeapStyle.accent
        case .waitingForBluetooth, .needsAttention: return LeapStyle.caution
        default: return LeapStyle.cool
        }
    }

    private func masked(_ identifier: UUID) -> String {
        "..." + identifier.uuidString.suffix(8)
    }
}

struct BLEPairingView: View {
    @Environment(VehicleStore.self) private var store

    private var controller: BLEVehicleController { store.bleController }

    var body: some View {
        List {
            Section {
                Label {
                    Text("请先在零跑官方 App 中临时关闭蓝牙钥匙，或解除蓝牙钥匙绑定，再返回这里搜索。官方 App 占用蓝牙连接时，可能搜索不到车辆。请保持手机系统蓝牙开启。")
                        .font(.subheadline)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(LeapStyle.cool)
                }
            } header: {
                Text("配对前准备")
            }

            Section { NavigationLink("蓝牙诊断") { BLEDiagnosticsView() } }
            Section {
                pairingStatus
            } header: {
                Text("当前车辆")
            }

            Section {
                if pairingCandidates.isEmpty {
                    HStack(spacing: 12) {
                        if controller.pairingState == .scanning {
                            ProgressView()
                        }
                        Text(controller.pairingState == .scanning ? "正在搜索附近车辆" : "没有发现车辆")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(pairingCandidates) { device in
                        Button {
                            controller.pair(to: device.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "car.side.fill")
                                    .foregroundStyle(LeapStyle.cool)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.name)
                                        .foregroundStyle(.primary)
                                    Text("\(device.maskedIdentifier)  ·  \(device.rssi) dBm")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .disabled(isPairingBusy)
                    }
                }

                if case .failed = controller.pairingState {
                    if controller.bluetoothState == .poweredOff || controller.bluetoothState == .unauthorized {
                        Button {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        } label: {
                            Label("打开系统设置", systemImage: "gear")
                        }
                    } else if controller.bluetoothState != .unsupported {
                        Button {
                            Task { await store.prepareBLEPairing() }
                        } label: {
                            Label("重新搜索", systemImage: "arrow.clockwise")
                        }
                    }
                }
            } header: {
                Text("附近车辆")
            } footer: {
                Text("只有通过当前 VIN 完整认证的候选车辆才会保存为绑定。")
            }
        }
        .navigationTitle("绑定车辆")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background { LeapBackground(tint: LeapStyle.cool) }
        .task { await store.prepareBLEPairing() }
        .onDisappear {
            if controller.pairingState != .bound {
                controller.cancelPairing()
            }
        }
    }

    @ViewBuilder
    private var pairingStatus: some View {
        switch controller.pairingState {
        case .idle, .preparing:
            Label("正在准备蓝牙", systemImage: "hourglass")
        case .scanning:
            Label("请选择车辆", systemImage: "scope")
        case .connecting:
            Label("正在连接", systemImage: "link")
        case .authenticating:
            Label("正在验证车辆身份", systemImage: "checkmark.shield")
        case .bound:
            Label("绑定成功", systemImage: "checkmark.circle.fill")
                .foregroundStyle(LeapStyle.accent)
        case .failed(let message):
            Label {
                Text(message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LeapStyle.caution)
            }
        }
    }

    private var isPairingBusy: Bool {
        switch controller.pairingState {
        case .connecting, .authenticating, .bound: return true
        default: return false
        }
    }

    private var pairingCandidates: [BLEDiscoveredDevice] {
        controller.devices.filter(\.advertisesTargetService)
    }
}
