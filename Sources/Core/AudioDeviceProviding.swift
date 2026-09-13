enum AudioDeviceProviderError: Error {
    case inputDeviceEnumerationFailed
}

/// CoreAudio 访问抽象：策略层只依赖本协议，测试注入 Fake 实现。
protocol AudioDeviceProviding: AnyObject {
    /// 当前所有输入设备。失败与“成功但列表为空”必须区分。
    func listInputDevices() throws -> [AudioInputDevice]

    /// 当前默认输入设备。
    func currentInputDevice() -> AudioInputDevice?

    /// 按 Device UID 设置默认输入设备。
    @discardableResult
    func setInputDevice(uid: String) -> Bool
}
