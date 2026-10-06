/// Reusable request/response isolates for plugin-owned background work.
/// The owner disposes each worker. Domain-specific worker protocols are private.
library;

export 'src/services/background_worker.dart'
    show
        BackgroundWorker,
        BackgroundWorkerEntrypoint,
        BackgroundWorkerException,
        BackgroundWorkerOperationHandler,
        serveBackgroundWorker;
