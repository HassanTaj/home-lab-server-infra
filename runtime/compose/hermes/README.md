# Hermes Agent

Hermes is the private inference runtime behind Yui. Home Assistant Assist is
the phone chat interface; there is no separate phone web app.

## Runtime

- Hermes Agent and Ollama are pinned by image digest in Compose.
- Local inference uses Qwen3.5 4B from `/srv/homelab/appdata/ollama`.
- Hermes state and its API key live in `/srv/homelab/appdata/hermes`.
- Ollama is available only on the private Compose network.
- The Hermes API is published on `127.0.0.1:8642` for the host-networked Home
  Assistant container. It is not exposed to NetBird, LAN, or the public edge.
- Hermes toolsets remain disabled. In Home Assistant, leave **Control Home
  Assistant** off until a separate permission review.
- The Ollama Cloud model names supplied by the owner are candidates only. They
  are not enabled; selecting one would send conversation prompts for hosted
  inference and needs an explicit decision.

## First-time setup

On the homelab:

```sh
cd /srv/homelab-demo/runtime/compose/hermes
sudo install -d -m 0700 /srv/homelab/appdata/hermes
sudo chown 10000:10000 /srv/homelab/appdata/hermes
sudo install -m 0600 config.yaml /srv/homelab/appdata/hermes/config.yaml
sudo install -m 0600 SOUL.md /srv/homelab/appdata/hermes/SOUL.md
sudo chown 10000:10000 /srv/homelab/appdata/hermes/config.yaml /srv/homelab/appdata/hermes/SOUL.md
sudo install -d -m 0700 /srv/homelab/appdata/ollama
docker compose --profile cli up -d ollama
docker compose --profile cli exec ollama ollama pull qwen3.5:4b
```

Hermes uses `http://ollama:11434/v1`, with Ollama thinking disabled. CPU
responses can be slow.

## Use the CLI

```sh
cd /srv/homelab-demo/runtime/compose/hermes
docker compose --profile cli run --rm -it hermes
```

## Use Yui in Home Assistant

Start the local inference API:

```sh
cd /srv/homelab-demo/runtime/compose/hermes
docker compose --profile home-assistant up -d ollama hermes-api
```

In Home Assistant, add the [**Llama.cpp** conversation integration](https://www.home-assistant.io/integrations/llama_cpp) with base URL
`http://127.0.0.1:8642/v1`, select model `hermes-agent`, and provide the API key
from `/srv/homelab/appdata/hermes/.env`. Set concise Yui instructions and keep
**Control Home Assistant** off. Select the resulting conversation agent in the
Assist pipeline, then open Assist chat from the Home Assistant phone app or
browser.

Do not publish port 8642 beyond loopback or enable Hermes tools for this setup.
