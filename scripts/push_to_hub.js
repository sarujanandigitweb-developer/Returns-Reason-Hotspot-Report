// push_to_hub.js — generic hub push script, identical for every team member.
//
// Usage:
//   node push_to_hub.js <member_name> <page_slug> "<page_title>" <path_to_html_file>
//
// Requires env var HUB_DB_URL (ask DWC — never hardcode it here).
// This is the shared connection also used by Manoranjini and Peries — it
// has access beyond this one table, so this script only ever touches
// varman_aios.hub_pages, and only via the upsert below. Don't repurpose it.
// Optional env var PGSSL=require if the connection needs SSL.

const fs = require('fs');
const { Client } = require('pg');

const [, , memberName, pageSlug, pageTitle, htmlPath] = process.argv;

if (!memberName || !pageSlug || !pageTitle || !htmlPath) {
  console.error(
    'Usage: node push_to_hub.js <member_name> <page_slug> "<page_title>" <path_to_html_file>'
  );
  process.exit(1);
}

if (!process.env.HUB_DB_URL) {
  console.error('Missing HUB_DB_URL environment variable.');
  process.exit(1);
}

if (!fs.existsSync(htmlPath)) {
  console.error(`File not found: ${htmlPath}`);
  process.exit(1);
}

const html = fs.readFileSync(htmlPath, 'utf8');

const client = new Client({
  connectionString: process.env.HUB_DB_URL,
  ssl: process.env.PGSSL === 'require' ? { rejectUnauthorized: false } : false,
});

async function main() {
  await client.connect();
  try {
    const res = await client.query(
      `INSERT INTO varman_aios.hub_pages (member_name, page_slug, page_title, html_content)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (member_name, page_slug)
       DO UPDATE SET page_title   = EXCLUDED.page_title,
                     html_content = EXCLUDED.html_content,
                     updated_at   = now()
       RETURNING id, member_name, page_slug, updated_at;`,
      [memberName, pageSlug, pageTitle, html]
    );
    console.log('Pushed successfully:', res.rows[0]);
  } finally {
    await client.end();
  }
}

main().catch((err) => {
  console.error('Push failed:', err.message);
  process.exit(1);
});
