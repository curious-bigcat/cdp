author: GPT-5.1 Codex
id: acxiom-retail-snowflake-hightouch
audience: solutions-architects, data-engineers, marketing-ops
language: en
summary: End-to-end Snowflake retail CDP workflow leveraging Acxiom's Data Enrichment native app and Hightouch Customer Studio.
environments: snowflake, hightouch
status: Draft

# Retail Snowflake CDP with Acxiom Data Enrichment and Hightouch

## Overview
This guide walks through a composable CDP pattern for retailers who want to append Acxiom's premium consumer intelligence inside Snowflake and then activate audiences via Hightouch Customer Studio. The workflow keeps PII inside your Snowflake account, uses Snowflake-native automation for recurring enrichment, and syncs audiences downstream through Hightouch's no-code UI or SQL models. Learn more about the joint approach in Hightouch's [Snowflake CDP overview](https://hightouch.com/solutions/snowflake-cdp?utm_source=openai) and retail-specific activation ideas on their [retail solution page](https://hightouch.com/solutions/retail?utm_source=openai).

### Architecture at a glance
1. **Snowflake core** – Database, schemas, and worksheets in `worksheets/` provision landing, model, and app layers.
2. **Acxiom Data Enrichment app** – Installed from Marketplace; executes `DATA_ENRICHMENT` against your curated input view and returns Retail bundle attributes (Cyber Monday propensity, on-demand grocery shoppers, warehouse club membership, etc.)
3. **Audience marts** – Curated using `worksheets/aurora_cdp_audience_marts.sql` for Hightouch.
4. **Hightouch Customer Studio** – Builds segments, syncs to Braze/Meta, and powers measurement.

## Prerequisites
- Snowflake account with `ACCOUNTADMIN` rights and Snowsight/SnowSQL access.
- Ability to install the "Acxiom Data Enrichment" native app from Snowflake Marketplace (Acxiom must complete business credentialing before production runs).
- Hightouch workspace (preferably provisioned through Partner Connect so Snowflake credentials are auto-created).
- Access to `/Users/bsuresh/Documents/cdp/Data Enrichment Native App in Snowflake User Guide (1).pdf` and the companion data dictionary for attribute definitions.

## Step-by-step implementation

### 1. Bootstrap Snowflake objects (Worksheet 1)
Run `worksheets/aurora_snowflake_enrichment.sql` in SnowSQL or Snowsight to:
- Create the `aurora_cdp` database, schemas (`raw`, `model`, `app`), and admin role/warehouse.
- Load sample retail customer PII records with loyalty + purchase context.
- Publish the `model.customer_enrich_input` view that exactly matches Acxiom’s required schema (all fields present even if null).

> ✅ Tip: The worksheet also seeds QA queries and a scheduled task that replays the stored procedure monthly.

### 2. Install and validate the Acxiom native app
1. In Snowsight, open **Marketplace → Apps → "Acxiom Data Enrichment"** and click **Get**.
2. Provide a database name such as `AURORA_APP`, fill the registration form, accept the terms, and wait for Acxiom to complete credentialing.
3. Navigate to **Data Products → Apps → Acxiom Data Enrichment** and open the in-app README for the exact schema names.
4. Execute the About Me proc for troubleshooting context:
   ```sql
   call ABOUT_ME.ABOUT_ME(app_db_name => 'AURORA_APP');
   ```

### 3. Enrich customer records
Still inside Snowsight, run the **Section 5** block from `aurora_snowflake_enrichment.sql`:
```sql
call DATA_ENRICHMENT('AURORA_CDP.MODEL.CUSTOMER_ENRICH_INPUT');
```
The output lands inside `AURORA_APP.REALID_RESULTS` with the suffix `_dataenrichment`. The worksheet persists those rows back into `aurora_cdp.app.customer_enriched` so they remain queryable outside the application environment.

### 4. Build audience-ready marts (Worksheet 2)
Execute `worksheets/aurora_cdp_audience_marts.sql` to create:
- `dim_customer_enriched` – a clean dimension table with Retail bundle metrics (Cyber Monday ranks, On-demand delivery propensities, etc.).
- `vw_customer_traits` – business-friendly trait labels such as "Luxury Cyber Monday" or "Warehouse Loyalist".
- `vw_customer_incremental` – rolling 24-hour view for Hightouch Live Sync.
- `vw_enrichment_kpis` – aggregate KPIs for dashboards.

### 5. Wire up Hightouch Customer Studio
1. **Connect via Partner Connect** – Launch Hightouch from Snowsight’s Partner Connect tab; this auto-creates Snowflake roles/warehouse scoped to Hightouch.
2. **Create a Snowflake source** in Hightouch that points to `aurora_cdp` (use key pair auth where possible).
3. **Model the data** – Use Hightouch’s SQL editor or dbt adapter to select from `dim_customer_enriched` and `vw_customer_traits`.
4. **Customer Studio audience** – Drag fields, filter on `primary_segment = 'Luxury Cyber Monday'`, ensure `opt_in = true`, and preview counts before publishing.
5. **Destinations** – Configure Braze/Klaviyo/Meta syncs, mapping hashed identifiers and scheduling hourly (Braze) vs. daily (Meta) cadences.
6. **Measurement** – Enable Hightouch Measurement to capture holdout vs. test performance; push lift tables back into Snowflake for governance.

### 6. Operational best practices
- **Match-rate QA** – Track match %, attribute fill, and CPM tiers using the QA queries inside Worksheet 1.
- **Data refresh** – Acxiom refreshes source data monthly; rerun the stored procedure whenever you need the latest attributes.
- **Security** – PII never leaves your Snowflake account. Hightouch hashing ensures downstream platforms only receive salted identifiers.
- **Cost management** – Batch records to stay within favorable CPM tiers; the first 1,000 matched records per Snowflake org are free each month.

## Deliverables in this repo
| Asset | Description |
| --- | --- |
| `worksheets/aurora_snowflake_enrichment.sql` | Provisioning + enrichment worksheet |
| `worksheets/aurora_cdp_audience_marts.sql` | Audience mart and trait creation worksheet |
| `references/acxiom-retail-snowflake-hightouch.md` | This implementation guide |

## Next steps
- Swap the sample insert statements with your anonymized production extracts.
- Parameterize the tasks with Snowflake variables or dbt macros for CI/CD.
- Extend audience traits with additional Acxiom Retail attributes listed in the Excel data dictionary.
- Layer on reverse ETL tests (dbt assertions + Hightouch sync alerts) before going live.
