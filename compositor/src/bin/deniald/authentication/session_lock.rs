//! logind requests close the same native gate as an explicit shell lock.
//! Unlock signals deliberately do not authenticate or open that gate.

use super::*;
use futures_lite::{StreamExt, future};
use zbus::zvariant::OwnedObjectPath;

const SERVICE: &str = "org.freedesktop.login1";
const MANAGER: &str = "/org/freedesktop/login1";
const SESSION_INTERFACE: &str = "org.freedesktop.login1.Session";
const POLL_INTERVAL: Duration = Duration::from_millis(250);
const RETRY_INTERVAL: Duration = Duration::from_secs(2);

fn stopping(shared: &SharedAuthentication) -> bool {
    lock_unpoisoned(&shared.state).stopping
}

pub(super) fn run_worker(shared: &Arc<SharedAuthentication>) {
    future::block_on(async {
        while !stopping(shared) {
            let result = async {
                let connection = zbus::connection::Builder::system()?
                    .method_timeout(Duration::from_secs(3))
                    .build()
                    .await?;
                monitor(&connection, shared).await
            }
            .await;
            if let Err(error) = result
                && !stopping(shared)
            {
                warn!(%error, "logind session lock monitoring is unavailable; retrying");
            }
            let retry = Instant::now() + RETRY_INTERVAL;
            while !stopping(shared) && Instant::now() < retry {
                async_io::Timer::after(POLL_INTERVAL).await;
            }
        }
    });
}

async fn monitor(connection: &zbus::Connection, shared: &SharedAuthentication) -> zbus::Result<()> {
    let bus = zbus::fdo::DBusProxy::new(connection).await?;
    // Resolve the process's actual session, then pin subscriptions to logind's
    // unique owner and the returned object path. Never subscribe to session/auto:
    // it is a method-call alias, not the path used by session signals.
    let manager = zbus::Proxy::new(
        connection,
        SERVICE,
        MANAGER,
        "org.freedesktop.login1.Manager",
    )
    .await?;
    let _: OwnedObjectPath = manager
        .call("GetSessionByPID", &(std::process::id(),))
        .await?;
    let owner = bus.get_name_owner(SERVICE.try_into()?).await?;
    let manager = zbus::Proxy::new(
        connection,
        owner.clone(),
        MANAGER,
        "org.freedesktop.login1.Manager",
    )
    .await?;
    let path: OwnedObjectPath = manager
        .call("GetSessionByPID", &(std::process::id(),))
        .await?;
    let session = zbus::Proxy::new(connection, owner, path, SESSION_INTERFACE).await?;
    let mut locks = session.receive_signal("Lock").await?;
    let mut owners = session.receive_owner_changed().await?;
    let mut published_hint = None;
    let mut hint_retry = Instant::now();
    while !stopping(shared) {
        // PAM can finish before the compositor has balanced client input. Keep
        // the hint locked until that native routing boundary acknowledges it.
        let locked = shared.locked.load(Ordering::Acquire)
            || shared.security_gate_locked.load(Ordering::Acquire);
        if published_hint != Some(locked) && Instant::now() >= hint_retry {
            match session.call::<_, _, ()>("SetLockedHint", &(locked,)).await {
                Ok(()) => published_hint = Some(locked),
                Err(error) => {
                    warn!(%error, "could not publish logind session lock state; retrying");
                    hint_retry = Instant::now() + RETRY_INTERVAL;
                }
            }
        }
        let signal = future::race(
            future::race(async { Some(locks.next().await) }, async {
                owners.next().await;
                Some(None)
            }),
            async {
                async_io::Timer::after(POLL_INTERVAL).await;
                None
            },
        )
        .await;
        match signal {
            Some(Some(message)) => {
                message.body().deserialize::<()>()?;
                lock_session(shared);
                info!("locked the session on logind request");
            }
            Some(None) => {
                return Err(zbus::Error::Failure(
                    "logind session owner disappeared".into(),
                ));
            }
            None => {}
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use zbus::blocking::connection::Builder;

    const PATH: &str = "/org/freedesktop/login1/session/test";

    struct Manager;
    #[zbus::interface(name = "org.freedesktop.login1.Manager")]
    impl Manager {
        #[zbus(name = "GetSessionByPID")]
        fn get_session_by_pid(&self, pid: u32) -> OwnedObjectPath {
            assert_eq!(pid, std::process::id());
            PATH.try_into().unwrap()
        }
    }

    struct Session(mpsc::Sender<bool>);
    #[zbus::interface(name = "org.freedesktop.login1.Session")]
    impl Session {
        fn set_locked_hint(&self, locked: bool) {
            self.0.send(locked).unwrap();
        }
    }

    #[test]
    fn private_bus_lock_filters_sender_and_session_and_never_accepts_unlock() {
        if std::env::var_os("DENIAL_SESSION_LOCK_TEST_BUS").is_none() {
            return;
        }
        let (hints, received) = mpsc::channel();
        let server = Builder::session()
            .unwrap()
            .name(SERVICE)
            .unwrap()
            .serve_at(MANAGER, Manager)
            .unwrap()
            .serve_at(PATH, Session(hints))
            .unwrap()
            .build()
            .unwrap();
        let controller = AuthenticationController::with_backend(
            Box::new(UnavailableBackend {
                reason: "test backend".into(),
            }),
            false,
        )
        .unwrap();
        let shared = Arc::clone(&controller.shared);
        let worker = thread::spawn(move || {
            future::block_on(async {
                let client = zbus::connection::Builder::session()
                    .unwrap()
                    .method_timeout(Duration::from_secs(2))
                    .build()
                    .await
                    .unwrap();
                monitor(&client, &shared).await.unwrap();
            })
        });
        assert!(!received.recv_timeout(Duration::from_secs(3)).unwrap());
        let forged = Builder::session().unwrap().build().unwrap();
        forged
            .emit_signal(None::<&str>, PATH, SESSION_INTERFACE, "Lock", &())
            .unwrap();
        server
            .emit_signal(
                None::<&str>,
                "/org/freedesktop/login1/session/other",
                SESSION_INTERFACE,
                "Lock",
                &(),
            )
            .unwrap();
        assert!(received.recv_timeout(Duration::from_millis(600)).is_err());
        assert!(!controller.locked());

        // Capability guards must not suppress an explicit logind request.
        lock_unpoisoned(&controller.shared.state).automatic_lock =
            lock_capability::Capability::Unavailable;
        server
            .emit_signal(None::<&str>, PATH, SESSION_INTERFACE, "Lock", &())
            .unwrap();
        assert!(received.recv_timeout(Duration::from_secs(3)).unwrap());
        assert!(controller.locked());
        assert!(controller.security_gate_locked());
        server
            .emit_signal(None::<&str>, PATH, SESSION_INTERFACE, "Unlock", &())
            .unwrap();
        assert!(received.recv_timeout(Duration::from_millis(600)).is_err());
        assert!(controller.locked());

        // Simulate PAM completion. The hint remains true until the compositor
        // applies its input boundary and acknowledges the unlock.
        controller.shared.locked.store(false, Ordering::Release);
        assert!(received.recv_timeout(Duration::from_millis(600)).is_err());
        controller.acknowledge_unlocked_boundary();
        assert!(!received.recv_timeout(Duration::from_secs(3)).unwrap());
        lock_unpoisoned(&controller.shared.state).stopping = true;
        worker.join().unwrap();
    }
}
