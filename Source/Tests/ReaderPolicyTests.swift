import Foundation
import CoreGraphics
@main struct PolicyTests {
    static func main() throws {
        let policy=ReaderPolicy(port:43187,key:String(repeating:"a",count:64))
        let assets=["/":Data("reader".utf8),"/reader.js":Data("script".utf8),"/reader.css":Data("style".utf8)]
        let secondaryDisplay = CGRect(x: -1440, y: 24, width: 1440, height: 852)
        let centered = ScreenGeometry.centeredFrame(CGSize(width: 446, height: 600), in: secondaryDisplay)
        precondition(centered.midX == secondaryDisplay.midX && centered.midY == secondaryDisplay.midY)
        precondition(secondaryDisplay.contains(centered))
        let sample=ReaderSnapshot(revision:7,text:"我喜欢学习。\n日本語\n한국어",status:"Ready",language:"zh-Hans")
        func request(_ path:String="/",method:String="GET",host:String="127.0.0.1:43187",extra:String="")->String {
            "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\n\(extra)"
        }
        var count=0
        func check(_ source:String,_ code:Int) {
            let reply=policy.route(source,snapshot:sample,assets:assets)
            precondition(reply.status==code,"Expected \(code), received \(reply.status) for \(source)");count+=1
        }
        check(request(),200)
        check(request("/reader.js"),200)
        check(request("/reader.css"),200)
        check(request("/state"),403)
        let auth="X-OCRCompanion-Session: \(policy.key)\r\nSec-Fetch-Site: same-origin\r\n"
        check(request("/state",extra:auth),200)
        let data=policy.route(request("/state",extra:auth),snapshot:sample,assets:assets).body
        let decoded = try JSONDecoder().decode(ReaderSnapshot.self,from:data)
        precondition(decoded.text==sample.text)
        check(request("/state",extra:"X-OCRCompanion-Session: bad\r\nSec-Fetch-Site: same-origin\r\n"),403)
        check(request("/state",extra:auth+"Origin: https://evil.example\r\n"),403)
        check(request(host:"evil.example"),403)
        check(request(host:"localhost:43187"),403)
        check(request(host:"127.0.0.1:43188"),403)
        check(request(extra:"Sec-Fetch-Site: cross-site\r\n"),403)
        check(request(extra:"Sec-Fetch-Site: same-site\r\n"),403)
        check(request(extra:"Origin: null\r\n"),403)
        check(request(method:"POST"),405)
        check(request(method:"OPTIONS"),405)
        check(request(extra:"Host: evil.example\r\n"),400)
        check(request(extra:"Transfer-Encoding: chunked\r\n"),403)
        check(request(extra:"Content-Length: 12\r\n"),403)
        check(request("/../macOS/Sources/Setup.swift"),404)
        check(request("/%2e%2e/secret"),404)
        check(request("/?session=secret"),404)
        check(request("/ocr"),404)
        check("invalid",400)
        let observation = Data("""
        {"textRevision":0,"words":[{"surface":"学习","key":"学习","status":5,"gradeable":true}],
         "lookup":{"surface":"学习","key":"学习","reading":"xué xí","definition":"to learn","status":5}}
        """.utf8)
        func slukaReply(_ body: Data, headers: String? = nil) -> ReaderReply {
            let signedHeaders = headers ?? auth + "Origin: \(policy.origin)\r\n"
            let fields = signedHeaders + "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
            return policy.route(request("/sluka", method: "POST", extra: fields),
                                snapshot: sample, assets: assets, body: body)
        }
        let accepted = slukaReply(observation)
        precondition(accepted.status == 204 && accepted.sluka?.words.first?.status == 5)
        precondition(accepted.sluka?.lookup?.definition == "to learn")
        precondition(slukaReply(observation, headers: auth).status == 403)
        precondition(slukaReply(observation, headers: auth + "Origin: https://example.org\r\n").status == 403)
        let text = String(decoding: observation, as: UTF8.self)
        precondition(slukaReply(Data(text.replacingOccurrences(of: "textRevision\":0", with: "textRevision\":1").utf8)).status == 409)
        precondition(slukaReply(Data(text.replacingOccurrences(of: "学习", with: "无关").utf8)).status == 409)
        precondition(slukaReply(Data(text.replacingOccurrences(of: "status\":5", with: "status\":100").utf8)).status == 409)
        precondition(slukaReply(Data(repeating: 0, count: ReaderPolicy.maxSlukaBody + 1)).status == 400)
        precondition(slukaReply(Data("broken".utf8)).status == 400)
        print("Passed authenticated Sluka mirror, revision, payload and source validation")
        let command = SlukaCommand(id: "test-command", textRevision: 0, surface: "学习", key: "学习",
                                   expectedStatus: 5, grade: 2,
                                   expiresAt: Int64(Date().timeIntervalSince1970 * 1_000) + 30_000)
        let noControlRequest = ReaderRequest(request("/state", extra: auth))!
        let claimedRequest = ReaderRequest(request("/state", extra: auth + "X-OCRCompanion-View: compact\r\nX-OCRCompanion-Controls: ready\r\n"))!
        let ordinary = policy.route(noControlRequest, snapshot: sample, assets: assets, body: Data(), command: command)
        let eligible = policy.route(claimedRequest, snapshot: sample, assets: assets, body: Data(), command: command)
        let ordinarySnapshot = try JSONDecoder().decode(ReaderSnapshot.self, from: ordinary.body)
        let eligibleSnapshot = try JSONDecoder().decode(ReaderSnapshot.self, from: eligible.body)
        precondition(ordinarySnapshot.command == nil)
        precondition(eligibleSnapshot.command?.id == command.id)
        var pending = BoundedSlukaCommand(request: command, callback: { _, _ in })
        func result(_ id: String = "test-command", outcome: SlukaCommandResult.Outcome = .applied,
                    status: Int = 2) -> SlukaCommandResult {
            SlukaCommandResult(id: id, textRevision: 0, outcome: outcome, status: status, lookup: nil)
        }
        precondition(!pending.accepts(result()))
        pending.offered = true
        precondition(!pending.accepts(result()))
        pending.committed = true
        precondition(pending.accepts(result()))
        precondition(!pending.accepts(result("another-command")))
        precondition(!pending.accepts(result(status: 5)))
        let badCommit = Data("{\"id\":\"test-command\",\"textRevision\":0}".utf8)
        let commit = request("/sluka-commit", method: "POST", extra: auth
            + "Content-Type: application/json\r\nContent-Length: \(badCommit.count)\r\n")
        precondition(policy.route(commit, snapshot: sample, assets: assets, body: badCommit).status == 403)
        let closed = Data("{}".utf8)
        let closedHeaders = "Content-Type: application/json\r\nContent-Length: 2\r\n"
        let unsignedClose = request("/sluka-disconnect", method: "POST", extra: closedHeaders)
        precondition(policy.route(unsignedClose, snapshot: sample, assets: assets, body: closed).status == 403)
        let signedClose = request("/sluka-disconnect", method: "POST", extra: auth + closedHeaders
                                  + "Origin: \(policy.origin)\r\n")
        precondition(policy.route(signedClose, snapshot: sample, assets: assets, body: closed).status == 204)
        print("Passed one-shot grade acknowledgment, scope, status and native authorization checks")
        var lease = ReaderLease()
        let firstReader = UUID(), reloadedReader = UUID()
        precondition(!lease.poll(firstReader, joining: false, at: 1))
        precondition(lease.poll(firstReader, joining: true, at: 1))
        precondition(lease.poll(reloadedReader, joining: true, at: 2))
        precondition(!lease.owns(firstReader, at: 2))
        precondition(!lease.poll(firstReader, joining: false, at: 3))
        precondition(lease.owns(reloadedReader, at: 3))
        precondition(!lease.isActive(at: 77))
        let source = CGPoint.zero, edge = CGPoint(x: 0, y: 32)
        precondition(ScreenGeometry.isMovingThroughHoverGap(CGPoint(x: 4, y: 18), from: .zero, source: source, edge: edge))
        precondition(!ScreenGeometry.isMovingThroughHoverGap(CGPoint(x: 26, y: 18), from: .zero, source: source, edge: edge))
        precondition(!ScreenGeometry.isMovingThroughHoverGap(CGPoint(x: 4, y: 18), from: CGPoint(x: 4, y: 18), source: source, edge: edge))
        print("Passed reader replacement, lease expiry and directional hover checks")
        let size=CGSize(width:1440,height:900)
        let rect=CGRect(x:100,y:150,width:300,height:200)
        for scale: CGFloat in [1,1.5,2] {
            let crop=ScreenGeometry.crop(rect,displaySize:size,scale:scale)!
            precondition(crop.sourceRect==CGRect(x:100,y:550,width:300,height:200))
            precondition(crop.pixelWidth==Int(300*scale) && crop.pixelHeight==Int(200*scale))
        }
        precondition(ScreenGeometry.crop(CGRect(x:-1,y:0,width:300,height:200),displaySize:size,scale:2)==nil)
        precondition(ScreenGeometry.crop(CGRect(x:1400,y:0,width:300,height:200),displaySize:size,scale:2)==nil)
        precondition(ScreenGeometry.crop(CGRect(x:0,y:0,width:300,height:10),displaySize:size,scale:2)==nil)
        precondition(ScreenGeometry.crop(rect,displaySize:size,scale: .infinity)==nil)
        precondition(ScreenGeometry.crop(rect,displaySize:size,scale:0)==nil)
        precondition(ScreenGeometry.crop(CGRect(x:0,y:0,width:10000,height:10000),displaySize:CGSize(width:10000,height:10000),scale:2)==nil)
        let window = CGRect(x:-1200,y:140,width:800,height:600)
        precondition(ScreenGeometry.appKitRect(fromQuartz:CGRect(x:-1200,y:250,width:800,height:600),primaryTop:990)==window)
        precondition(ScreenGeometry.cursorRegion(at:CGPoint(x:-1150,y:710),within:window)==CGRect(x:-1200,y:400,width:800,height:340))
        precondition(ScreenGeometry.imageSize(for:window.size,scale:2)==CGSize(width:1600,height:1200))
        let capped = ScreenGeometry.imageSize(for:CGSize(width:10_000,height:10_000),scale:2)!
        precondition(capped.width * capped.height <= 40_000_000 && capped.width == capped.height)
        precondition(ScreenGeometry.imageSize(for:CGSize(width:5,height:800),scale:2)==nil)
        let local = CGRect(x:200,y:150,width:400,height:300)
        let pixels = ScreenGeometry.windowImageCrop(local,windowSize:window.size,imageSize:CGSize(width:1600,height:1200))!
        precondition(pixels==CGRect(x:400,y:300,width:800,height:600))
        precondition(ScreenGeometry.pixelCropScreenBounds(pixels,imageSize:CGSize(width:1600,height:1200),in:window)==local.offsetBy(dx:-1200,dy:140))
        precondition(ScreenGeometry.windowImageCrop(local,windowSize:CGSize(width:350,height:200),imageSize:CGSize(width:700,height:400))==nil)
        precondition(ScreenGeometry.screenBounds(forNormalizedFrame:CGRect(x:0.25,y:0.5,width:0.5,height:0.25),in:window)==CGRect(x:-1000,y:440,width:400,height:150))
        let sampleText = "🙂第一句。第二句！第三句。"
        precondition(ScreenGeometry.sentence(in:sampleText,atUTF16Offset:0)=="🙂第一句。")
        precondition(ScreenGeometry.sentence(in:sampleText,atUTF16Offset:6)=="第二句！")
        precondition(ScreenGeometry.sentence(in:sampleText,atUTF16Offset:sampleText.utf16.count)==nil)
        print("Passed \(count) reader access-policy cases, multilingual JSON round-trip and 21 capture-geometry cases")
    }
}
