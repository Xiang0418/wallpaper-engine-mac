import SwiftUI
@main struct InstalledPreviewChecks {
 @MainActor static func main() async throws {
  _ = NSApplication.shared
  let url=URL(fileURLWithPath:CommandLine.arguments[1])

  let host=NSHostingView(rootView:GifImage(contentsOf:url,animates:true).resizable())
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:240),styleMask:[.titled],backing:.buffered,defer:false)
  window.contentView=host; window.orderFront(nil)
  func imageView(_ v:NSView)->NSImageView? { if let i=v as? NSImageView{return i};return v.subviews.compactMap{imageView($0)}.first }
  var frames=Set<Int>()
  for _ in 0..<12 {
   try await Task.sleep(nanoseconds:70_000_000)
   if let v=imageView(host),let rep=v.image?.representations.first as? NSBitmapImageRep {
    frames.insert((rep.value(forProperty:.currentFrame) as? NSNumber)?.intValue ?? -1)
   }
  }
  precondition(frames.count>1,"GIF must advance actual frames")
  let original=imageView(host)!.image
  host.rootView=GifImage(contentsOf:url,animates:true).resizable()
  try await Task.sleep(nanoseconds:100_000_000)
  precondition(imageView(host)!.image === original,"Unrelated updates must preserve GIF identity")
  host.rootView=GifImage(contentsOf:url,animates:false).resizable()
  try await Task.sleep(nanoseconds:100_000_000)
  precondition(imageView(host)!.image === original,"Pause must not reload image")
  precondition(!imageView(host)!.animates)
  let rep=imageView(host)!.image!.representations.first as! NSBitmapImageRep
  let paused=rep.value(forProperty:.currentFrame) as! NSNumber
  try await Task.sleep(nanoseconds:350_000_000)
  precondition(rep.value(forProperty:.currentFrame) as! NSNumber == paused)
  window.orderOut(nil)
  print("PASS: local GIF advances, updates preserve image identity, pause stops frames")
 }
}
