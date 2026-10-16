@main struct PreviewChecks {
 @MainActor static func main() async throws {
  _ = NSApplication.shared
  let url = URL(string:"http://127.0.0.1:18749/preview.gif")!
  let data = try await WorkshopPreviewLoader.fetch(url)
  let sharedURL = url.deletingLastPathComponent().appendingPathComponent("slow-shared")
  let cancelled = Task { try await WorkshopPreviewLoader.fetch(sharedURL) }
  let survivor = Task { try await WorkshopPreviewLoader.fetch(sharedURL) }
  try await Task.sleep(nanoseconds: 50_000_000)
  cancelled.cancel()
  do { _ = try await cancelled.value; fatalError("Cancelled consumer must not publish") }
  catch is CancellationError {} catch { fatalError("Unexpected cancellation error") }
  let survivingData = try await survivor.value
  precondition(survivingData == data)
  _ = try await WorkshopPreviewLoader.fetch(sharedURL)
  let (stats, _) = try await URLSession.shared.data(from: url.deletingLastPathComponent().appendingPathComponent("stats"))
  let counts = try JSONDecoder().decode([String: Int].self, from: stats)
  precondition(counts["/slow-shared"] == 1, "Concurrent consumers and a cache hit must use one HTTP request")
  try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<8 {
          let next = url.deletingLastPathComponent().appendingPathComponent("slow-\(index)")
          group.addTask { _ = try await WorkshopPreviewLoader.fetch(next) }
      }
      try await group.waitForAll()
  }
  let (limitedStats, _) = try await URLSession.shared.data(from: url.deletingLastPathComponent().appendingPathComponent("stats"))
  let limitedCounts = try JSONDecoder().decode([String: Int].self, from: limitedStats)
  precondition((limitedCounts["peak"] ?? 0) <= 4, "At most four preview transfers may run together")
  let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("preview-cache-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: temporary) }
  let disk = WorkshopPreviewDataStore(directory: temporary, memoryLimit: 0)
  let diskURL = url.deletingLastPathComponent().appendingPathComponent("slow-disk")
  _ = try await disk.fetch(diskURL)
  // A new store has no memory or HTTP cache, so this checks actual persistent reuse.
  let reopened = WorkshopPreviewDataStore(directory: temporary, memoryLimit: 0)
  let fromDisk = try await reopened.fetch(diskURL)
  precondition(fromDisk == data)
  let (diskStats, _) = try await URLSession.shared.data(from: url.deletingLastPathComponent().appendingPathComponent("stats"))
  let diskCounts = try JSONDecoder().decode([String: Int].self, from: diskStats)
  precondition(diskCounts["/slow-disk"] == 1)
  for file in try FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil) {
      try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -1900)], ofItemAtPath: file.path)
  }
  _ = try await reopened.fetch(diskURL)
  let (expiredStats, _) = try await URLSession.shared.data(from: url.deletingLastPathComponent().appendingPathComponent("stats"))
  let expiredCounts = try JSONDecoder().decode([String: Int].self, from: expiredStats)
  precondition(expiredCounts["/slow-disk"] == 2,
               "Expired entries must be downloaded again")
  let scheduled = WorkshopPreviewDataStore(directory: temporary.appendingPathComponent("scheduler"), concurrency: 1)
  func scheduledURL(_ name: String) -> URL { url.deletingLastPathComponent().appendingPathComponent("slow-" + name) }
  let blocker = Task { try await scheduled.fetch(scheduledURL("blocker")) }
  for _ in 0..<50 {
      let (bytes, _) = try await URLSession.shared.data(from: url.deletingLastPathComponent().appendingPathComponent("stats"))
      if try JSONDecoder().decode([String: Int].self, from: bytes)["/slow-blocker"] != nil { break }
      try await Task.sleep(nanoseconds: 2_000_000)
  }
  let offscreen = Task { try await scheduled.fetch(scheduledURL("offscreen")) }
  let visibleCard = Task { try await scheduled.fetch(scheduledURL("visible")) }
  let detail = Task { try await scheduled.fetch(scheduledURL("detail"), priority: .detail) }
  try await Task.sleep(nanoseconds: 20_000_000)
  offscreen.cancel()
  do { _ = try await offscreen.value; fatalError("Offscreen queue entry should cancel") }
  catch is CancellationError {} catch { fatalError("Unexpected cancellation error") }
  _ = try await blocker.value
  _ = try await detail.value
  _ = try await visibleCard.value
  let (orderData, _) = try await URLSession.shared.data(from: url.deletingLastPathComponent().appendingPathComponent("order"))
  let order = try JSONDecoder().decode([String].self, from: orderData)
  precondition(!order.contains("/slow-offscreen"), "Cancelled queued images must never reach the server")
  precondition(order.firstIndex(of: "/slow-detail")! < order.firstIndex(of: "/slow-visible")!,
               "The open preview must get priority over queued cards")
  let first = try await WorkshopPreviewLoader.decode(data, maxPixelSize: 600)
  let second = try await WorkshopPreviewLoader.decode(data)
  precondition(first.1 && second.1 && first.0 !== second.0, "GIF playback state must stay independent")
  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 900,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  let png = bitmap.representation(using: .png, properties: [:])!
  let small = try await WorkshopPreviewLoader.decode(png, maxPixelSize: 600)
  precondition(!small.1 && small.0.representations[0].pixelsWide == 600,
               "Static thumbnails must be decoded at card resolution")
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
  let visibilityURL = url.deletingLastPathComponent().appendingPathComponent("slow-visibility")
  let outside = CGRect(x: -10000, y: -10000, width: 100, height: 100)
  let thumbnail=NSHostingView(rootView:WorkshopAnimatedThumbnail(url:visibilityURL).environment(\.workshopViewport, outside))
  window.contentView=thumbnail
  try await Task.sleep(nanoseconds:100_000_000)
  let (hiddenStats, _) = try await URLSession.shared.data(from: url.deletingLastPathComponent().appendingPathComponent("stats"))
  let hiddenCounts = try JSONDecoder().decode([String: Int].self, from: hiddenStats)
  precondition(hiddenCounts["/slow-visibility"] == nil, "Laid-out offscreen thumbnails must not download")
  thumbnail.rootView = WorkshopAnimatedThumbnail(url:visibilityURL).environment(\.workshopViewport, nil)
  try await Task.sleep(nanoseconds:500_000_000)
  var thumbnailFrames=Set<Int>()
  for _ in 0..<12 {
   try await Task.sleep(nanoseconds:70_000_000)
   if let rep=imageView(thumbnail)?.image?.representations.first as? NSBitmapImageRep {
    thumbnailFrames.insert((rep.value(forProperty:.currentFrame) as? NSNumber)?.intValue ?? -1)
   }
  }
  precondition(thumbnailFrames.count>1,"Visible grid thumbnail must autoplay")
  thumbnail.rootView = WorkshopAnimatedThumbnail(url:visibilityURL).environment(\.workshopViewport, outside)
  try await Task.sleep(nanoseconds:100_000_000)
  precondition(imageView(thumbnail)?.animates != true, "Offscreen GIFs must stop animating")
  thumbnail.rootView = WorkshopAnimatedThumbnail(url:visibilityURL).environment(\.workshopViewport, nil)
  try await Task.sleep(nanoseconds:100_000_000)
  precondition(imageView(thumbnail)?.animates == true, "Returning to the viewport resumes GIF playback")
  let (returnStats, _) = try await URLSession.shared.data(from: url.deletingLastPathComponent().appendingPathComponent("stats"))
  let returnCounts = try JSONDecoder().decode([String: Int].self, from: returnStats)
  precondition(returnCounts["/slow-visibility"] == 1, "Scrolling back must reuse loaded imagery")
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
  print("PASS: disk cache/expiry, visibility/priority/queued cancellation, cache/coalescing/cancellation/concurrency, static downsampling, remote GIF, HTTP/size failures, real frame advancement, pause without reload, paused frame stability, preview snapshots")
 }
}
