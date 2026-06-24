import Foundation

@objc(OKDiskXPCStatusProtocol)
public protocol OKDiskXPCStatusProtocol {
    func getStatusJSON(reply: @escaping (NSString) -> Void)
}

public final class EngineHost {
    public let service: OKDiskService
    private var xpcListener: OKDiskXPCListener?

    public init(configPath: String? = nil, hostname: String = okdiskCurrentHostname(), environment: OKDiskEnvironment = .development) {
        self.service = OKDiskService(configPath: configPath, hostname: hostname, environment: environment)
    }

    public func startXPCListener(name: String = OKDiskXPCListener.defaultServiceName) {
        guard xpcListener == nil else { return }
        let listener = OKDiskXPCListener(service: service, serviceName: name)
        listener.resume()
        xpcListener = listener
    }

    public func stopXPCListener() {
        xpcListener?.invalidate()
        xpcListener = nil
    }
}

public final class OKDiskXPCListener: NSObject, NSXPCListenerDelegate {
    public static let defaultServiceName = "com.okdisk.service.xpc"

    private let listener: NSXPCListener
    private let exportedObject: OKDiskXPCExportedObject

    public init(service: OKDiskService, serviceName: String = OKDiskXPCListener.defaultServiceName) {
        self.listener = NSXPCListener(machServiceName: serviceName)
        self.exportedObject = OKDiskXPCExportedObject(service: service)
        super.init()
        listener.delegate = self
    }

    public func resume() {
        listener.resume()
    }

    public func invalidate() {
        listener.invalidate()
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: OKDiskXPCStatusProtocol.self)
        newConnection.exportedObject = exportedObject
        newConnection.resume()
        return true
    }
}

public final class OKDiskXPCExportedObject: NSObject, OKDiskXPCStatusProtocol {
    private let service: OKDiskService

    init(service: OKDiskService) {
        self.service = service
    }

    public func getStatusJSON(reply: @escaping (NSString) -> Void) {
        Task {
            let status = await service.getStatus()
            let data = (try? okdiskJSONEncoder(pretty: true).encode(status)) ?? Data("{}".utf8)
            reply(String(decoding: data, as: UTF8.self) as NSString)
        }
    }
}
