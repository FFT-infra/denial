# Plugin SDK review

Reviewed 2026-09-29. The typed composition core and surface API are sound.

1. **High:** removing a work-area provider cannot clear its native reservation.
2. **Medium:** contracts needed only by unselected providers can block composition.
3. **Fixed:** shared platform state is separate from plugin-owned reference gestures, layout and transitions.
4. **Fixed:** focused service capability interfaces isolate feature dependencies; `ShellServices` remains the host bundle.
5. **Fixed:** explicit SDK exports hide implementation helpers; focused libraries expose backend, lifecycle, worker and wire APIs.
6. **Docs:** the Dart SDK README incorrectly says the manager and surface hosting do not exist.

No handwritten SDK/UI import cycles or SDK dependencies on UI plugins were found.
The analyzer cache deliberately depends on isolated private analyzer APIs.

Further findings: [shell and SDK follow-up review](SHELL_SDK_FOLLOWUP_REVIEW.md).
