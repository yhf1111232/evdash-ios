//
//  ContentView.swift
//  EvDash
//
//  主界面：设备页 + 参数页（首版聚焦「搜索连接 + 参数读取显示」）
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var ble: BleManager
    @State private var tab: Tab = .devices

    enum Tab: String, CaseIterable {
        case devices = "设备"
        case params  = "参数"
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 状态条
                statusBar

                Divider().background(Color.white.opacity(0.08))

                // 内容
                Group {
                    switch tab {
                    case .devices: DeviceListView()
                    case .params:  ParamListView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().background(Color.white.opacity(0.08))

                // 底部页签
                tabBar
            }
            .background(Color(red: 0.024, green: 0.035, blue: 0.055).ignoresSafeArea())
            .navigationTitle("EV 车机")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 状态条

    private var statusBar: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .shadow(color: dotColor.opacity(0.8), radius: 4)

            Text(ble.state.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()

            if let rt = ble.realtime {
                Text("\(Int(rt.busVoltage))V")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.18, green: 0.82, blue: 1.0))
                Text("\(Int(rt.busCurrent))A")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.18, green: 0.82, blue: 1.0))
                Text("\(Int(rt.rpm))r")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var dotColor: Color {
        switch ble.state {
        case .connected:  return Color(red: 0.22, green: 0.84, blue: 0.48)
        case .scanning:   return Color(red: 1.0, green: 0.72, blue: 0.25)
        case .connecting: return Color(red: 1.0, green: 0.72, blue: 0.25)
        case .failed:     return Color(red: 1.0, green: 0.36, blue: 0.36)
        case .idle:       return Color(white: 0.35)
        }
    }

    // MARK: - 页签

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button {
                    tab = t
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: t == .devices ? "antenna.radiowaves.left.and.right" : "slider.horizontal.3")
                            .font(.system(size: 18))
                        Text(t.rawValue)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(tab == t ? Color(red: 0.18, green: 0.82, blue: 1.0) : Color(white: 0.45))
                }
            }
        }
        .background(Color.white.opacity(0.03))
    }
}

// MARK: - 设备页

struct DeviceListView: View {
    @EnvironmentObject private var ble: BleManager

    var body: some View {
        VStack(spacing: 12) {
            // 操作按钮
            HStack(spacing: 10) {
                Button {
                    ble.startScan()
                } label: {
                    Label("搜索设备", systemImage: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color(red: 0.18, green: 0.82, blue: 1.0).opacity(0.15))
                        .foregroundStyle(Color(red: 0.18, green: 0.82, blue: 1.0))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Button {
                    ble.stopScan()
                } label: {
                    Text("停止")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(Color.white.opacity(0.06))
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Button {
                    ble.disconnect()
                } label: {
                    Text("断开")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(Color.white.opacity(0.06))
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // 设备列表
            if ble.devices.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 34))
                        .foregroundStyle(Color(white: 0.3))
                    Text(emptyHint)
                        .font(.system(size: 14))
                        .foregroundStyle(Color(white: 0.4))
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(ble.devices) { dev in
                            deviceRow(dev)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }

            // 提示
            if !ble.lastMessage.isEmpty {
                Text(ble.lastMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 10)
            }
        }
    }

    private var emptyHint: String {
        if case .failed(let m) = ble.state { return m }
        if ble.state == .scanning { return "正在搜索…\n请确认控制器已上电" }
        return "点击「搜索设备」开始扫描\n支持 GEKOO-BLE / ZX-D30"
    }

    private func deviceRow(_ dev: DiscoveredDevice) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(dev.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(dev.id.uuidString.prefix(8) + "…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(white: 0.4))
            }
            Spacer()
            Text("\(dev.rssi) dBm")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Button {
                ble.connect(dev)
            } label: {
                Text("连接")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color(red: 0.18, green: 0.82, blue: 1.0).opacity(0.16))
                    .foregroundStyle(Color(red: 0.18, green: 0.82, blue: 1.0))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 参数页

struct ParamListView: View {
    @EnvironmentObject private var ble: BleManager
    @State private var expanded: Set<Int> = []
    @State private var showWriteConfirm = false
    @State private var editWords: [Int] = []

    private var grouped: [(ParamGroup, [ParamDef])] { Params.grouped() }

    var body: some View {
        VStack(spacing: 10) {
            // 操作条
            HStack(spacing: 10) {
                Button {
                    ble.readParams()
                } label: {
                    Label("读取参数", systemImage: "arrow.down.circle")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color(red: 0.18, green: 0.82, blue: 1.0).opacity(0.15))
                        .foregroundStyle(Color(red: 0.18, green: 0.82, blue: 1.0))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .disabled(ble.state != .connected)

                Button {
                    ble.readBleKey()
                } label: {
                    Text("读密码")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.06))
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .disabled(ble.state != .connected)

                Spacer()

                if let w = ble.paramWords {
                    Text("\(w.count) 字")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(white: 0.4))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if ble.paramWords == nil {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 34))
                        .foregroundStyle(Color(white: 0.3))
                    Text("连接控制器后点「读取参数」")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(white: 0.4))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(grouped, id: \.0.id) { group, items in
                            groupSection(group, items)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private func groupSection(_ g: ParamGroup, _ items: [ParamDef]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if expanded.contains(g.id) { expanded.remove(g.id) }
                else { expanded.insert(g.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded.contains(g.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(red: 0.18, green: 0.82, blue: 1.0))
                    Text(g.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 0.18, green: 0.82, blue: 1.0))
                    Text(g.tip)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.4))
                        .lineLimit(1)
                    Spacer()
                    Text("\(items.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(white: 0.35))
                }
            }

            if expanded.contains(g.id) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(items) { p in
                        paramCell(p)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func paramCell(_ p: ParamDef) -> some View {
        let words = ble.paramWords ?? []
        let v = ParamCodec.decode(p, words: words)
        let text = ParamCodec.display(p, v)
        let unit = ParamCodec.unitSuffix(p)

        return VStack(alignment: .leading, spacing: 3) {
            Text(p.name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 2) {
                Text(text)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.4))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

#Preview {
    ContentView()
        .environmentObject(BleManager())
}
