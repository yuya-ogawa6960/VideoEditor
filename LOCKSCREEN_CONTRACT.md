# Lock-screen processing contract (internal)

Goal: export and transcription keep running while the iPhone is locked.
User device: iOS 27, app installed with AltStore (free Apple ID). AltStore rewrites CFBundleIdentifier at install time
(typically `com.personal.videoeditor` → `com.personal.videoeditor.<TEAMID>`), but does NOT rewrite
`BGTaskSchedulerPermittedIdentifiers`. Today we submit `BGContinuedProcessingTaskRequest(identifier: "com.personal.videoeditor.export")`,
which does not start with the runtime bundle id, so iOS rejects it and the export only gets ~30 s of background time.

## Part 1 — Continued processing (iOS 26+) for export and transcription
Files: Sources/App/AppLifecycle.swift, Sources/Engine/ExportManager.swift, Sources/Engine/FilterEngine.swift (context selection only),
project.yml (Info.plist permitted identifiers), new Sources/App/ContinuedProcessing.swift.

- Info.plist `BGTaskSchedulerPermittedIdentifiers`: keep `com.personal.videoeditor.export` and ADD wildcard entries that also match the
  AltStore-rewritten id: `com.personal.videoeditor.*` (and keep the exact one). Request identifiers are built at RUNTIME from
  `Bundle.main.bundleIdentifier` so they always start with the real bundle id: `<bundleID>.export.<UUID>` and `<bundleID>.transcribe.<UUID>`.
- Registration: for BGContinuedProcessingTask, register the launch handler for the exact runtime identifier right before submitting
  (`BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in ... }`), guarded so a failure to register never crashes
  (register returns Bool; also catch the case where it was already registered). Keep the old launch-time registration only if harmless.
- `ContinuedProcessing.swift` (all iOS 26 code behind `#if compiler(>=6.2)` + `@available(iOS 26.0, *)`; on older systems everything
  becomes a no-op that returns nil):
  ```swift
  enum ContinuedProcessingKind: String { case export, transcribe }
  final class ContinuedProcessingHandle {
      func update(completed: Double /* 0...1 */, subtitle: String?)   // updates task.progress (totalUnitCount 1000) and subtitle
      func finish(success: Bool)                                     // setTaskCompleted, idempotent
      var wasExpired: Bool { get }                                   // system/user stopped it
      var onExpire: (() -> Void)?                                    // called on expiration (main actor)
      var gpuGranted: Bool { get }
  }
  enum ContinuedProcessing {
      /// Must be called from a user action on the main actor while the app is in the foreground.
      @MainActor static func begin(kind: ContinuedProcessingKind, title: String, subtitle: String, wantsGPU: Bool) -> ContinuedProcessingHandle?
      /// Last submit/register result for diagnostics (Japanese, e.g. 「ロック中の継続: 有効」 or 「ロック中の継続: 使えません(理由)」)
      static var lastDiagnostic: String { get }
      static var runtimeBundleIdentifier: String { get }
  }
  ```
  Use `BGContinuedProcessingTaskRequest(identifier:title:subtitle:)`, `strategy = .fail` (so we know immediately if it cannot run;
  fall back to beginBackgroundTask), and when `wantsGPU` and `BGTaskScheduler.supportedResources.contains(.gpu)` set
  `requiredResources = .gpu`. Record `gpuGranted` accordingly. The launch handler stores the task in the handle, sets
  `expirationHandler` → `wasExpired = true; onExpire?()`.
- ExportManager: replace its own continued-processing code with `ContinuedProcessing.begin(kind: .export, ...)`; report progress via
  `handle.update`; finish on success/failure/cancel; on expiration cancel the export cleanly (existing behaviour). Keep the
  `beginBackgroundTask` fallback. Keep `attachContinuedProcessingTask` only if other code still calls it (grep), else remove.
- GPU in background: today the compositor switches to a CPU CIContext when `AppLifecycle.shared.isInBackground`. Add
  `AppLifecycle.shared.backgroundGPUAllowed: Bool` (thread-safe, set true while an export handle with `gpuGranted` is active) and make
  `FilterEngineContexts.current` use the GPU context when `isInBackground && backgroundGPUAllowed`.
- Diagnostics: `ContinuedProcessing.lastDiagnostic` updated on every begin.

## Part 2 — Background URLSession for cloud transcription
Files: Sources/Engine/CloudTranscriber.swift, Sources/Engine/TranscriptionService.swift, Sources/App/VideoEditorApp.swift,
new Sources/Engine/CloudBackgroundUploader.swift, Sources/Views/SubtitleEditorView.swift (pending-job UI only),
Sources/Views/TranscriptionSettingsView.swift (diagnostics row only).

- `CloudBackgroundUploader` (singleton, NSObject, URLSessionDataDelegate/URLSessionTaskDelegate) with
  `URLSessionConfiguration.background(withIdentifier: runtimeBundleID + ".cloud-upload")`, `sessionSendsLaunchEvents = true`,
  `isDiscretionary = false`, `allowsCellularAccess = true`, `httpMaximumConnectionsPerHost = 4`.
  Jobs persisted under Application Support/CloudJobs/<jobID>/: `job.json` (language, model, pieces: index, absolute source range,
  clip id, clip timeline mapping inputs, status, attempts), `body-<i>.bin` (multipart body file), `result-<i>.json` (response data).
  `uploadTask(with: request, fromFile: bodyURL)`, `taskDescription = "<jobID>|<pieceIndex>"`. Response bytes accumulated per task
  (didReceive data) and written on completion; HTTP status checked (2xx → done; 429/5xx/transient → re-enqueue with attempts+1 up to 6;
  401 → job failed with the existing Japanese message).
  API:
  ```swift
  final class CloudBackgroundUploader: NSObject {
      static let shared: CloudBackgroundUploader
      func enqueue(job: CloudJobManifest) throws           // writes files, starts all upload tasks
      func waitForCompletion(jobID: UUID, progress: @escaping (Int /*done*/, Int /*total*/) -> Void) async throws -> [Int: Data]  // resumes when all pieces have results; cancellable (cancels tasks)
      func pendingJobs() -> [CloudJobManifest]               // jobs with results not yet consumed (e.g. app was killed)
      func results(for jobID: UUID) -> [Int: Data]?
      func discard(jobID: UUID)
      var backgroundCompletionHandler: (() -> Void)?        // set by AppDelegate; called in urlSessionDidFinishEvents on main
  }
  struct CloudJobManifest: Codable, Identifiable { ... }   // enough to rebuild TimedTokens → cues later (piece ranges in source seconds, clip id, clip startTime/speed/timeline start, language, model, created date, project id)
  ```
- VideoEditorApp: add `@UIApplicationDelegateAdaptor(AppDelegate.self)`; AppDelegate implements
  `application(_:handleEventsForBackgroundURLSession:completionHandler:)` → touch `CloudBackgroundUploader.shared` (recreates the
  session with the same identifier) and store the completion handler.
- CloudTranscriber: new path used by TranscriptionService for the cloud engine: extract ALL pieces to files first (fast, foreground),
  build multipart bodies to files, enqueue one job, then `waitForCompletion`, then parse each result with the existing parser and
  produce tokens exactly as today (same offsets/clamping). Keep the old in-process path as a fallback if the background session
  cannot be created.
- TranscriptionService: wrap the whole run in `ContinuedProcessing.begin(kind: .transcribe, title: "文字起こし", subtitle: "...", wantsGPU: false)`
  (Part 1 API; nil on older iOS → existing beginBackgroundTask fallback stays), update progress; the AI polish step waits for foreground
  only if no continued-processing handle is active (with an active handle, run it in background).
  Status text while locked: 「ロック中も処理を続けています」 when a handle or background uploads are active.
- Pending results recovery: SubtitleEditorView shows a banner when `CloudBackgroundUploader.shared.pendingJobs()` has a job for this
  project: 「前回の文字起こし結果があります」 with 「取り込む」 (rebuild cues via TranscriptionService helper
  `func cues(fromPendingJob:snapshot:language:) async throws -> [SubtitleCue]`, then polish if enabled, then replace/append per the
  current choice) and 「破棄」.
- TranscriptionSettingsView: a 「診断」 section showing `ContinuedProcessing.runtimeBundleIdentifier` and `ContinuedProcessing.lastDiagnostic`.
