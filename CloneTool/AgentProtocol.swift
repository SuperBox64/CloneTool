import Foundation

@objc protocol AgentToolProtocol {
    func execute(script: String, instanceID: String, withReply reply: @escaping (Int32, String) -> Void)
    func cancelOperation(instanceID: String, withReply reply: @escaping () -> Void)
}

@objc protocol AgentProgressProtocol {
    func progressUpdate(_ line: String)
}
