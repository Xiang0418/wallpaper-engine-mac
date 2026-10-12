@main struct PreviewChecks {
 @MainActor static func main() async throws {
  _ = NSApplication.shared
  let url = URL(string:"http://127.0.0.1:18749/preview.gif")!
  let data = try await WorkshopPreviewLoader.fetch(url)
  let source = CGImageSourceCreateWithData(data as CFData,nil)!
  precondition(CGImageSourceGetCount(source)==2)
  for path in ["missing","oversized"] {
   do { _ = try await WorkshopPreviewLoader.fetch(URL(string:"http://127.0.0.1:18749/"+path)!); fatalError("Accepted bad response") }
   catch { print("Rejected",path) }
  }
  let image=NSImage(data:data)!
  let host=NSHostingView(rootView:WorkshopPreviewImage(image:image,playing:true))
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
  host.rootView=WorkshopPreviewImage(image:image,playing:false)
  try await Task.sleep(nanoseconds:100_000_000)
  precondition(imageView(host)!.image === original,"Pause must not reload image")
  precondition(!imageView(host)!.animates)
  let rep=imageView(host)!.image!.representations.first as! NSBitmapImageRep
  let paused=rep.value(forProperty:.currentFrame) as! NSNumber
  try await Task.sleep(nanoseconds:350_000_000)
  precondition(rep.value(forProperty:.currentFrame) as! NSNumber == paused)
  let full=NSHostingView(rootView:WorkshopImagePreview(item:WorkshopItem(title:"Animated preview test",previewImageURL:url)))
  window.setContentSize(NSSize(width:720,height:520));window.contentView=full
  try await Task.sleep(nanoseconds:700_000_000)
  var fullFrames=Set<Int>()
  for _ in 0..<12 {
   try await Task.sleep(nanoseconds:70_000_000)
   if let rep=imageView(full)?.image?.representations.first as? NSBitmapImageRep {
    fullFrames.insert((rep.value(forProperty:.currentFrame) as? NSNumber)?.intValue ?? -1)
   }
  }
  precondition(fullFrames.count>1,"Full AppKit-hosted preview must animate, not only the image component")
  let thumbnail=NSHostingView(rootView:WorkshopAnimatedThumbnail(url:url))
  window.contentView=thumbnail
  try await Task.sleep(nanoseconds:500_000_000)
  var thumbnailFrames=Set<Int>()
  for _ in 0..<12 {
   try await Task.sleep(nanoseconds:70_000_000)
   if let rep=imageView(thumbnail)?.image?.representations.first as? NSBitmapImageRep {
    thumbnailFrames.insert((rep.value(forProperty:.currentFrame) as? NSNumber)?.intValue ?? -1)
   }
  }
  precondition(thumbnailFrames.count>1,"Visible grid thumbnail must autoplay")
  window.contentView=full
  for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",NSAppearance.Name.darkAqua)] {
   window.appearance=NSAppearance(named:appearance); full.appearance=NSAppearance(named:appearance)
   try await Task.sleep(nanoseconds:250_000_000)
   full.layoutSubtreeIfNeeded()
   let bitmap=full.bitmapImageRepForCachingDisplay(in:full.bounds)!
   full.cacheDisplay(in:full.bounds,to:bitmap)
   try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"build/preview-tests/"+name+".png"))
  }
  window.orderOut(nil)
  print("PASS: remote GIF, HTTP/size failures, real frame advancement, pause without reload, paused frame stability, preview snapshots")
 }
}
