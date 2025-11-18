# Composable CDP Quickstarts

This repository captures hands-on guides, SQL worksheets, and activation playbooks for building a composable customer data platform (CDP) on Snowflake. The latest addition focuses on a retail scenario that enriches customer profiles with Acxiom's Data Enrichment native application and activates those insights via Hightouch Customer Studio (see additional guidance in `references/acxiom-retail-snowflake-hightouch.md`).

> Looking for the high-level story first? Read the reference guide, then come back to this README for the exact commands and checklist.

## Repository layout

| Path | Description |
| --- | --- |
| `references/` | Markdown guides for Snowflake + partner patterns (Braze, Hightouch, LiveRamp, etc.). |
| `references/acxiom-retail-snowflake-hightouch.md` | End-to-end walkthrough for the Acxiom × Hightouch retail flow. |
| `worksheets/aurora_snowflake_enrichment.sql` | Snowflake worksheet that provisions roles/warehouses, seeds demo data, and runs the Acxiom `DATA_ENRICHMENT` proc. |
| `worksheets/aurora_cdp_audience_marts.sql` | Follow-on worksheet to build audience-ready marts and traits for Hightouch syncs. |

## Prerequisites
- Snowflake account with `ACCOUNTADMIN` rights and Snowsight/SnowSQL access.
- Ability to install the **Acxiom Data Enrichment** app from Snowflake Marketplace (Acxiom must approve your business credentials).
- Hightouch workspace connected to Snowflake, ideally created via Partner Connect so credentials are pre-provisioned ([Hightouch × Snowflake overview](https://hightouch.com/solutions/snowflake-cdp?utm_source=openai)).
- Destination marketing platforms (e.g., Braze, Meta Ads) connected to Hightouch; see the retail activation playbook for targeting ideas ([Hightouch retail solution](https://hightouch.com/solutions/retail?utm_source=openai)).

## Step-by-step implementation

### 0. Clone this repo
```bash
cd ~/Documents
git clone https://github.com/curious-bigcat/cdp.git
cd cdp
```

### 1. Bootstrap Snowflake (Worksheet 1)
1. Open Snowsight or SnowSQL.
2. Copy the contents of `worksheets/aurora_snowflake_enrichment.sql` into a worksheet.
3. Replace placeholders such as `<your_user>` with your Snowflake username.
4. Execute each section in order:
   - **Section 1** creates the `aurora_cdp_admin` role, warehouse, and database.
   - **Section 3** seeds the demo `customers_pi` table.
   - **Section 4** publishes the `model.customer_enrich_input` view that matches Acxiom's required schema (all columns must exist even when null, per the Acxiom guide).

### 2. Install the Acxiom Data Enrichment native app
1. In Snowsight, go to **Marketplace → Apps → “Acxiom Data Enrichment.”**
2. Click **Get**, pick a database name (e.g., `AURORA_APP`), fill the registration UI, and accept the terms.
3. After Acxiom credentials you, navigate to **Data Products → Apps** to access the README and stored procedures.
4. Verify the install by running:
   ```sql
   call ABOUT_ME.ABOUT_ME(app_db_name => 'AURORA_APP');
   ```

### 3. Run enrichment and persist results
1. Back in Worksheet 1, execute **Section 5** to call:
   ```sql
   call DATA_ENRICHMENT('AURORA_CDP.MODEL.CUSTOMER_ENRICH_INPUT');
   ```
2. Execute **Section 6** to copy the enriched output from `AURORA_APP.REALID_RESULTS` into `aurora_cdp.app.customer_enriched` for downstream use.
3. Run the QA queries in **Section 7** to confirm match rates and attribute fills.
4. (Optional) Resume the scheduled task in **Section 8** so enrichment re-runs monthly.

### 4. Build audience-ready marts (Worksheet 2)
1. Open `worksheets/aurora_cdp_audience_marts.sql` in Snowsight.
2. Execute all sections to:
   - Materialize `dim_customer_enriched` with select Retail bundle attributes (Cyber Monday propensities, on-demand delivery interest, warehouse club membership).
   - Create trait views (`vw_customer_traits`, `vw_customer_incremental`, `vw_enrichment_kpis`).
3. These views feed Hightouch models and dashboards; adjust the segment logic to mirror your retail personas.

### 5. Configure Hightouch activation
1. **Connect via Partner Connect** if you have not already (Admin → Partner Connect → Hightouch → Launch → Activate).
2. In Hightouch, create a Snowflake source pointing at `aurora_cdp` using the credentials created above.
3. Build models that select from `dim_customer_enriched` and `vw_customer_traits`.
4. Use Customer Studio to create audiences—for example, `primary_segment = 'Luxury Cyber Monday'` and `opt_in = true`.
5. Map and schedule syncs to your destinations (e.g., Braze, Meta). Hightouch can hash identifiers automatically before they leave Snowflake.
6. Enable Measurement to track holdouts and push lift metrics back into Snowflake for reporting (details in `references/acxiom-retail-snowflake-hightouch.md`).

### 6. Maintain and extend
- Refresh demo data by updating the `customers_pi` insert block or swapping in your own anonymized extracts.
- Expand trait logic with more attributes from the Acxiom Retail bundle listed in the Excel data dictionary.
- Automate validation with dbt tests, Snowflake tasks, and Hightouch sync alerts before productionizing.

## Need more context?
- `references/improving-ad-performance-capi-hightouch.md` covers Facebook CAPI reverse ETL patterns with Snowflake + Hightouch.
- `references/braze-*` guides show how to operationalize Braze campaigns using the same composable CDP foundation.

Open an issue or PR if you extend the workflow to additional verticals or activation channels.
