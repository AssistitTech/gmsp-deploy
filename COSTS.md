# What GMSP costs in Azure

GMSP runs in **your own** Azure subscription, so Azure bills you directly. With the recommended sizes, one MSP pays
about **$25-35 a month** in total. Almost all of it is the database and the portal plan; the rest is close to zero.

All figures are **approximate Azure list prices in US dollars** (Pay-As-You-Go, East US region).
Prices differ a little by region and currency, change over time, and do not include taxes or your own discounts. For
exact figures, use the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) with the services
below.

## Service by service

| Service (name in your resource group) | What GMSP uses it for | How Azure charges | Typical monthly cost for one MSP |
| --- | --- | --- | --- |
| Azure Database for PostgreSQL, flexible server, **Burstable B1ms** (`gmsp-db-<suffix>`) | GMSP's own database: tenants, roles, audit log, settings, reports | Per hour the server exists (compute), plus storage per GB | about **$13-15** compute |
| Database storage, 32 GB, plus backups (7 days) | The data itself | Per GB-month; backup storage up to the database size is included | about **$4** |
| Static Web App, **Standard** plan (`gmsp-portal-<suffix>`) | The portal you open in the browser, sign-in, roles, the link to the API | Flat price per app | **$9** |
| Function App, **Flex Consumption** plan (`gmsp-api-<suffix>`, plan `gmsp-plan-<suffix>`) | The API and the 5-minute timer (alerts, scheduled tasks) | Per GB-second while it runs and per execution, after a monthly free grant (below); nothing while idle | about **$0-2** |
| Storage account (`gmspfn<suffix>`) | The Function App's code package and its internal state | Per GB and per operation | under **$1** |
| Application Insights + Log Analytics workspace (`gmsp-api-<suffix>`, `gmsp-logs-<suffix>`) | Diagnostics of the API (errors, timings). GMSP's audit log is in the database, not here | Per GB ingested; the first 5 GB a month per billing account are free; the button sets a daily cap | about **$0-2** |
| Managed identities (`gmsp-api-<suffix>`'s own, `gmsp-github-deploy-<suffix>`) | Keyless access: to Google (through workload identity federation) and for your fork's deploy workflow | Free | **$0** |
| Microsoft Entra ID **Free** | Sign-in to the portal | Included with every Azure tenant | **$0** |
| Microsoft Entra ID **P1** (optional) | Conditional Access for portal sign-in (require MFA, compliant devices, locations) | Per user per month | about $6 per GMSP staff member, only if you want it |

### The API: Flex Consumption

GMSP's API runs on Azure Functions' **Flex Consumption** plan (installations made before v1.0.2 run on the older Linux
Consumption plan, which is billed much the same way and keeps working). Flex Consumption bills only while code runs:

- **Execution time:** the instance memory (GMSP uses 2 GB instances) times the seconds an instance is busy running
  GMSP, in GB-seconds (at least 1 second per execution, then in steps of 0.1 s). Microsoft's own worked example uses
  $0.000026 per GB-s; check the current rate on the [Azure Functions pricing
  page](https://azure.microsoft.com/pricing/details/functions/).
- **Executions:** about $0.40 per million.
- **Monthly free grant, per subscription:** **100,000 GB-s** and **250,000 executions** of on-demand use (Pay-As-You-Go
  and other paid subscriptions; it is shared by every Flex Consumption app in the subscription).

GMSP's 5-minute timer runs about 8,640 times a month. At a few seconds each on a 2 GB instance that is roughly 20,000 to
90,000 GB-s, inside the free grant; portal use adds a little. A typical MSP therefore pays **$0-2 a month** for the API;
a very busy portal might add a few dollars (each further 100,000 GB-s costs about $2.60).

**Always-ready instances are not used.** Flex Consumption can keep instances running all the time to avoid cold starts,
but those are billed around the clock and have no free grant. GMSP creates none: the first request after a quiet
period takes a few seconds longer, and that is all. The plan also caps the API at 10 instances, so a surge of requests
cannot run up the bill.

Google's side costs nothing extra for GMSP: the Workspace and Cloud APIs it calls are not billed per call, and the
keyless service account has no fee. GitHub Actions in your private fork uses a few minutes per deploy, well within the
free minutes of a GitHub plan.

## The expensive-size trap

PostgreSQL is the one place a wrong choice multiplies the bill. **Burstable** sizes (B1ms, B2s, B2ms) are made for
load like GMSP's: busy for a moment, idle most of the time. **General Purpose** sizes (D2s v3, D2ds v4 and up) cost
about **$125-145 a month**, roughly ten times B1ms, and GMSP does not need them.

The trap: **free trial, student and sponsorship subscriptions usually refuse every Burstable size**. An installer that
"tries until something works" then ends on General Purpose, and the trial credit or the first real bill disappears
fast. GMSP's installers never do that:

- the **Deploy to Azure** wizard detects the subscription type and stops on a trial / student / sponsorship
  subscription, shows the price beside every size, preselects B1ms and warns in red on a General Purpose choice;
- the **command-line installer** warns on such a subscription and asks before creating anything, shows every size
  with its price, and if Azure refuses the size you chose, it asks which region to try, never a bigger size.

The fix is the subscription, not the size: use a **Pay-As-You-Go** subscription, or upgrade the trial (Azure portal >
Subscriptions > your subscription > Upgrade; your credit and resources are kept). See Microsoft's
[upgrade instructions](https://learn.microsoft.com/azure/cost-management-billing/manage/upgrade-azure-subscription).

A subscription with a **spending limit** (trials, Visual Studio subscriptions) also has a second risk: when the credit
runs out, Azure stops everything in it, including your portal.

## Downsizing later

If your database ended up bigger than needed:

1. Azure portal > your resource group > `gmsp-db-<suffix>` > **Settings > Compute + storage**.
2. Compute tier **Burstable**, compute size **Standard_B1ms**. Save. The server restarts once (a minute or two of
   downtime); data and settings stay.
3. Storage can only grow, never shrink. 32 GB is plenty for one MSP.

Or with the Azure CLI:
`az postgres flexible-server update -g <resource-group> -n gmsp-db-<suffix> --tier Burstable --sku-name Standard_B1ms`.

If Azure refuses Burstable on your subscription, upgrade the subscription first (above), then downsize.

## Keeping an eye on it

- Azure portal > **Cost Management > Budgets**: create a monthly budget for the resource group (for example $40) with
  an email alert at 80%. It costs nothing.
- Everything GMSP creates carries the tag `app=gmsp`, so **Cost Management > Cost analysis**, grouped by tag, shows
  GMSP's total.
- Removing GMSP is deleting its resource group; the bill stops with it (export what you want to keep first:
  `INSTALL.md`, "Uninstalling").
