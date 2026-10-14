# CT-3-3 review fixes

The owner approved the remaining three review fixes for PR #14.

## Behavior

If a restored timer cover disappears before appearing, end its session and retain the accepted stored record. Present an explicit failure alert with Retry and Finish. Retry settles that record at the new tap and opens a new timer with a fresh owner identifier; repeated failures offer the same choices. Finish uses the existing revision-ordered clear and reports a failed clear. Once the cover appears, forget the pending restoration. Fresh timers retain their current dismissal behavior.

## Boundaries

Move BackgroundTaskClient and its token into a narrow BackgroundExecution library. AppFeature and WorkoutTimerFeature depend directly on it. Use the pinned Dependencies and DependenciesMacros products, not TCA, in the new library. The synchronous begin/async end interface and its documented lifecycle exception stay the same.

RunRecordFile remains an actor. Its synchronous revision check and file operation run on a dedicated serial DispatchQueue executor, apart from the reader and the cooperative pool. A failed newer revision still rejects older revisions. Keep directory creation on each write so a removed directory can be recovered, and reapply the backup exclusion when the directory is recreated.

## Constraints

- iOS 17+, Swift 6 complete strict concurrency, Xcode 26.5.
- Existing String Catalogs only, English and Russian; DesignSystem tokens only.
- No changes to saved-record schema, dependency versions or SwiftData persistence.
- Preserve the user's scheme edits and .DS_Store; work in the existing feature worktree.
- Required final verification: make ci and make verify-clean of exact final HEAD; update the existing PR through gh.
