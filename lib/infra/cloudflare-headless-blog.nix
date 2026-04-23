# ============================================================================
# CLOUDFLARE-HEADLESS-BLOG — Pangea declaration factory
# ============================================================================
#
# Produces a Pangea-Cloudflare Ruby template body for the standard
# "CMS-backed static blog with a webhook Worker" shape. Abstracts what
# `zuihitsu/pangea/zuihitsu.rb` does so every pleme-io blog declares its
# Cloudflare footprint identically.
#
# This is a *template builder* — it returns a string containing a Ruby
# `template :name do ... end` block. Consumers write it to
# `pangea/<blog>.rb` and hand it to the Pangea CLI.
#
# Shape of the emitted block (mirrors `zuihitsu.rb`):
#   - cloudflare_zone (optional — only if the zone is not already managed)
#   - cloudflare_pages_project
#   - cloudflare_pages_domain (custom subdomain)
#   - cloudflare_dns_record CNAME (proxied) → <project>.pages.dev
#   - cloudflare_workers_script (the webhook Worker)
#   - cloudflare_workers_route (webhook.<host>/*)
#   - cloudflare_dns_record AAAA (webhook placeholder)
#
# Paired with:
#   - `substrate/lib/build/rust/rust-static-site-flake.nix` (builds dist/)
#   - `substrate/lib/build/rust/cloudflare-worker-flake.nix` (builds the worker)
#   - `substrate/lib/build/web/cloudflare-pages-deploy.nix` (pushes dist/)

{ lib ? (import <nixpkgs> {}).lib }:

rec {
  # Return the full Ruby body for `pangea/<name>.rb`.
  #
  # Example:
  #   emitTemplate {
  #     name = "zuihitsu";
  #     pagesProjectName = "zuihitsu";
  #     workerScriptName = "zuihitsu-webhook";
  #     zoneName = "pleme.io";
  #     siteHost = "blog.pleme.io";
  #     webhookHost = "webhook.blog.pleme.io";
  #     manageZone = false;  # zone already owned elsewhere
  #   }
  emitTemplate = {
    name,
    pagesProjectName,
    workerScriptName,
    zoneName,
    siteHost,
    webhookHost,
    manageZone ? false,
    accountIdVar ? "cloudflare_account_id",
    apiTokenVar ? "cloudflare_api_token",
  }: let
    zoneBlock = if manageZone then ''
      zone = cloudflare_zone(
        :${lib.replaceStrings ["-"] ["_"] name}_zone,
        {
          account: { id: account },
          name: zone_name,
          type: 'full'
        }
      )
    '' else ''
      # Zone is managed elsewhere — consumer sets zone_id via `var(:zone_id)`.
      zone_id_ref = var(:zone_id)
    '';
    zoneIdRef = if manageZone then "zone.id" else "zone_id_ref";
  in ''
    # frozen_string_literal: true
    #
    # ${name} — Cloudflare Pages (static) + Worker (webhook) synthesis.
    # Generated from substrate/lib/infra/cloudflare-headless-blog.nix.
    # Rendered via pangea-cloudflare → Terraform JSON → tofu apply.

    require 'pangea'
    require 'pangea-cloudflare'

    template :${lib.replaceStrings ["-"] ["_"] name} do
      provider :cloudflare do
        api_token var(:${apiTokenVar})
      end

      account = var(:${accountIdVar})
      zone_name = var(:zone_name, default: '${zoneName}')
      site_host = var(:site_host, default: '${siteHost}')
      webhook_host = var(:webhook_host, default: '${webhookHost}')

      ${zoneBlock}

      # ── Pages (static site) ──────────────────────────────────────────
      pages = cloudflare_pages_project(
        :${lib.replaceStrings ["-"] ["_"] pagesProjectName},
        {
          account_id: account,
          name: '${pagesProjectName}',
          production_branch: 'main',
          build_config: { build_command: '', destination_dir: 'dist', root_dir: '' },
          deployment_configs: {
            production: {
              env_vars: {
                SITE_URL: { type: 'plain_text', value: "https://#{site_host}" }
              }
            }
          }
        }
      )

      cloudflare_pages_domain(
        :${lib.replaceStrings ["-"] ["_"] pagesProjectName}_domain,
        {
          account_id: account,
          project_name: pages.name,
          name: site_host
        }
      )

      cloudflare_dns_record(
        :${lib.replaceStrings ["-"] ["_"] name}_site_cname,
        {
          zone_id: ${zoneIdRef},
          name: site_host,
          type: 'CNAME',
          content: "#{pages.subdomain}",
          ttl: 1,
          proxied: true
        }
      )

      # ── Worker (webhook) ─────────────────────────────────────────────
      webhook = cloudflare_workers_script(
        :${lib.replaceStrings ["-"] ["_"] workerScriptName},
        {
          account_id: account,
          script_name: '${workerScriptName}',
          main_module: 'shim.mjs',
          compatibility_date: '2025-01-01',
          observability: { enabled: true, head_sampling_rate: 1 }
        }
      )

      cloudflare_workers_route(
        :${lib.replaceStrings ["-"] ["_"] workerScriptName}_route,
        {
          zone_id: ${zoneIdRef},
          pattern: "#{webhook_host}/*",
          script: webhook.script_name
        }
      )

      cloudflare_dns_record(
        :${lib.replaceStrings ["-"] ["_"] name}_webhook_cname,
        {
          zone_id: ${zoneIdRef},
          name: webhook_host,
          type: 'AAAA',
          content: '100::',
          ttl: 1,
          proxied: true
        }
      )
    end
  '';

  # Return a complete `pangea.yml` for a headless blog workspace.
  emitPangeaYml = { name, zoneName, siteHost, webhookHost }: ''
    name: ${name}
    provider: cloudflare

    templates:
      - ${name}

    variables:
      cloudflare_api_token:
        source: env
        env: CLOUDFLARE_API_TOKEN
        sensitive: true
      cloudflare_account_id:
        source: env
        env: CLOUDFLARE_ACCOUNT_ID
      zone_name:
        default: ${zoneName}
      site_host:
        default: ${siteHost}
      webhook_host:
        default: ${webhookHost}

    freescape:
      provider: cloudflare
      profile: always-free
  '';
}
