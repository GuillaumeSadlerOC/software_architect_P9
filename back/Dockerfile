# syntax=docker/dockerfile:1.7
# =============================================================================
# MicroCRM — Backend (Spring Boot 3.2 / Java 17)
# Multi-stage build: Temurin 17 JDK for build, Temurin 17 JRE for runtime.
# Non-root user, tini as PID 1, HEALTHCHECK via Actuator.
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1 — Build with the project's own Gradle wrapper (Gradle 8.7 pinned)
# -----------------------------------------------------------------------------
FROM eclipse-temurin:17-jdk-jammy AS builder

WORKDIR /workspace

# Copy only what is needed to resolve dependencies first — optimal layer cache.
# Any change to src/ alone will NOT invalidate the dependency-download layer.
COPY --chmod=0755 gradlew ./
COPY gradle ./gradle
COPY build.gradle settings.gradle ./

# Pre-download dependencies into the Gradle cache. `dependencies` task is
# lightweight and idempotent; the `|| true` guards against transient mirror
# hiccups so the real build below surfaces the actual error.
RUN ./gradlew --no-daemon --console=plain dependencies || true

# Copy sources last, then produce the fat jar.
# Tests are NOT executed here: CI runs them separately with proper reporting.
# Building without tests keeps Dockerfile builds fast and single-purpose.
COPY src ./src
RUN ./gradlew --no-daemon --console=plain clean bootJar -x test \
 && cp build/libs/microcrm-*-SNAPSHOT.jar build/libs/app.jar

# -----------------------------------------------------------------------------
# Stage 2 — Minimal runtime image
# -----------------------------------------------------------------------------
FROM eclipse-temurin:17-jre-jammy AS runtime

# OCI standard labels — traceability in registries & scanners
LABEL org.opencontainers.image.title="orion-microcrm-back" \
      org.opencontainers.image.description="Orion MicroCRM backend (Spring Boot 3.2)" \
      org.opencontainers.image.vendor="Orion" \
      org.opencontainers.image.source="https://github.com/OpenClassrooms-Student-Center/P7-FSJA" \
      org.opencontainers.image.licenses="MIT"

# Security: create an unprivileged user to run the JVM.
# No shell, no home directory — reduces the attack surface.
RUN groupadd --system --gid 1001 spring \
 && useradd --system --uid 1001 --gid spring --no-create-home --shell /usr/sbin/nologin spring

# tini: reap zombies + forward signals correctly to the JVM (SIGTERM → graceful shutdown).
# curl: needed by HEALTHCHECK to hit the Actuator endpoint.
# ca-certificates: keep TLS trust store current.
RUN apt-get update \
 && apt-get install -y --no-install-recommends tini curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder --chown=spring:spring /workspace/build/libs/app.jar /app/app.jar

USER spring

# JVM container-awareness: cap heap at 75% of cgroup memory limit.
# SPRING_PROFILES_ACTIVE can be overridden at deploy time (dev / prod).
ENV JAVA_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -Djava.security.egd=file:/dev/./urandom" \
    SERVER_PORT=8080 \
    SPRING_PROFILES_ACTIVE=prod

EXPOSE 8080

# Liveness/readiness contract: Actuator's /health is served once context is up.
# --start-period gives the JVM 40s to boot before failures count.
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${SERVER_PORT}/actuator/health" || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]

