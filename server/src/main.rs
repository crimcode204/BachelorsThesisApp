use axum::{Router, http::Method};
use tokio::signal;
use tower_http::{
    cors::{Any, CorsLayer},
    services::ServeDir,
};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

#[tokio::main]
async fn main() {
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| {
                format!("{}=debug,tower_http=debug", env!("CARGO_CRATE_NAME")).into()
            }),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods([Method::GET, Method::HEAD]);

    let app = Router::new()
        .nest_service("/video", ServeDir::new("../video"))
        .layer(cors);

    let listener = tokio::net::TcpListener::bind("[::]:3000").await.unwrap();

    tracing::debug!("Listening on {}", listener.local_addr().unwrap());

    let _ = axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await;
}

async fn shutdown_signal() {
    let ctrl_c = async {
        signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };
    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("failed to install signal handler")
            .recv()
            .await;
    };

    tokio::select! {
        _ = ctrl_c => {
          tracing::debug!("Initiating shutdown (SIGINT)...");
        },
        _ = terminate => {
          tracing::debug!("Initiating shutdown (SIGTERM)...");
        },
    }
}
