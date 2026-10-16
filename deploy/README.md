# zlrd + Prometheus + Grafana in five minutes

The agent runs on the host; this directory starts Prometheus, Alertmanager
and Grafana next to it with the zlrd dashboard and alert rules already
loaded. Needs Docker (Docker Desktop, OrbStack, or Docker Engine on Linux).

```bash
brew install alaleks/tap/zlrd
git clone --depth 1 https://github.com/alaleks/zlrd && cd zlrd/deploy

# One secret, shared by the agent and Prometheus.
openssl rand -hex 16 > zlrd.token

# Any log you have. --service names it on the dashboard.
zlrd --agent --metrics-token "$(cat zlrd.token)" \
  --service api=/var/log/app.log /var/log/app.log &

docker compose up -d
open http://localhost:3000   # Linux: xdg-open
```

Grafana opens on the zlrd dashboard, no login needed (it only listens on
`127.0.0.1`; `admin` / `admin` to edit). Prometheus is on
[:9090](http://localhost:9090), Alertmanager on [:9093](http://localhost:9093).

**Linux.** Install zlrd from [apt](../README.md#linux--apt-debian-ubuntu)
instead of brew, and start the agent with `--listen 0.0.0.0:9100`:
containers reach the host through the Docker bridge, not `127.0.0.1`, and
on the default address the dashboard stays empty. Keep port 9100 closed to
the outside. On macOS the default `127.0.0.1:9100` works.

Measured from a cold start, images included: 101 s on macOS (OrbStack,
`brew install` to data on the dashboard), about 3 minutes on a fresh Ubuntu
24.04 VM with Docker already installed.

## What is in here

| File | What it is |
| --- | --- |
| `docker-compose.yml` | The three services, ports bound to `127.0.0.1` |
| `prometheus/prometheus.yml` | Scrapes the agent with the token from `zlrd.token` |
| `prometheus/alerts.yml` | Alert rules — copy into any Prometheus as-is |
| `prometheus/alerts_test.yml` | Their tests: `promtool test rules alerts_test.yml` |
| `alertmanager/alertmanager.yml` | Routing; uncomment Telegram or Slack to get alerts in a chat |
| `grafana/dashboards/zlrd.json` | The dashboard; import it into an existing Grafana as-is |

## Alert rules

| Alert | Fires when |
| --- | --- |
| `ZlrdAgentDown` | Prometheus cannot scrape the agent for 2 minutes |
| `ZlrdServiceCrashed` | A service crashed in the last 5 minutes |
| `ZlrdServiceCrashLoop` | 3 crashes in 15 minutes (silences `ZlrdServiceCrashed`) |
| `ZlrdKernelOOM` | The kernel OOM-killed a process (`--kernel-probes`) |
| `ZlrdKernelSegfault` | A process segfaulted (`--kernel-probes`) |
| `ZlrdKernelPanicPreviousBoot` | The host came back from a kernel panic (`--kernel-probes`) |
| `ZlrdErrorRateHigh` | More than 1 error line a second for 10 minutes — tune it |

These alert on the agent's counters. The crash alerts zlrd sends itself
(chat, webhook) carry the stack trace; these carry the count, for a team
that already routes everything through Alertmanager.

## More hosts

Add a target per host to `prometheus/prometheus.yml`, each agent started
with the same token and `--listen 0.0.0.0:9100`, then
`docker compose restart prometheus`. The dashboard's **Host** selector picks
them up.
