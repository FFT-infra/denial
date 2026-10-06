/// Temporary, dismissible UI with managed focus, input and lifetime.
///
/// These are popup instances, not plugin contributions. Persistent plugin UI
/// declares ShellSurface in surfaces.dart; shell roots mount those declarations
/// using surface_hosting.dart. This library creates no second plugin registry.
library;

export 'src/widgets/shell_popup_host.dart'
    show
        ManagedShellPopup,
        ShellDismissPolicy,
        ShellPopupBuilder,
        ShellPopupController,
        ShellPopupHandle,
        ShellPopupHost,
        shellPopupControllerProvider;
