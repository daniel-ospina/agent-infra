import { google } from "googleapis";

function getAuthClient() {
  const clientId = process.env.GOOGLE_CLIENT_ID;
  const clientSecret = process.env.GOOGLE_CLIENT_SECRET;
  const refreshToken = process.env.GOOGLE_REFRESH_TOKEN;

  if (!clientId || !clientSecret || !refreshToken) {
    throw new Error(
      "Search Console OAuth not configured. Set GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_REFRESH_TOKEN in .env. Run auth script first."
    );
  }

  const oauth2Client = new google.auth.OAuth2(clientId, clientSecret);
  oauth2Client.setCredentials({ refresh_token: refreshToken });
  return oauth2Client;
}

function getDefaultSiteUrl(): string {
  return process.env.DEFAULT_SITE_URL ?? "https://eldato.com.mx";
}

export interface QueryAnalyticsParams {
  siteUrl?: string;
  startDate: string;
  endDate: string;
  dimensions?: string[];
  rowLimit?: number;
  dimensionFilterGroups?: any[];
}

export async function queryAnalytics(params: QueryAnalyticsParams) {
  const auth = getAuthClient();
  const searchconsole = google.searchconsole({ version: "v1", auth });

  const response = await searchconsole.searchanalytics.query({
    siteUrl: params.siteUrl ?? getDefaultSiteUrl(),
    requestBody: {
      startDate: params.startDate,
      endDate: params.endDate,
      dimensions: params.dimensions ?? ["query", "page"],
      rowLimit: params.rowLimit ?? 100,
      dimensionFilterGroups: params.dimensionFilterGroups,
    },
  });

  return response.data;
}

export async function getNearRankingKeywords(
  siteUrl?: string,
  startDate?: string,
  endDate?: string,
  minImpressions = 20
) {
  const now = new Date();
  const end = endDate ?? new Date(now.getTime() - 3 * 24 * 60 * 60 * 1000).toISOString().split("T")[0];
  const start = startDate ?? new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000).toISOString().split("T")[0];

  const data = await queryAnalytics({
    siteUrl,
    startDate: start,
    endDate: end,
    dimensions: ["query", "page"],
    rowLimit: 1000,
  });

  const rows = (data.rows ?? []).filter((row: any) => {
    const position = row.position ?? 0;
    const impressions = row.impressions ?? 0;
    return position >= 8 && position <= 20 && impressions >= minImpressions;
  });

  rows.sort((a: any, b: any) => (b.impressions ?? 0) - (a.impressions ?? 0));

  return {
    dateRange: { startDate: start, endDate: end },
    minImpressions,
    count: rows.length,
    rows: rows.map((row: any) => ({
      query: row.keys?.[0],
      page: row.keys?.[1],
      clicks: row.clicks,
      impressions: row.impressions,
      ctr: Math.round((row.ctr ?? 0) * 10000) / 100, // percentage
      position: Math.round((row.position ?? 0) * 10) / 10,
    })),
  };
}

export async function getLowCtrQueries(
  siteUrl?: string,
  startDate?: string,
  endDate?: string
) {
  const now = new Date();
  const end = endDate ?? new Date(now.getTime() - 3 * 24 * 60 * 60 * 1000).toISOString().split("T")[0];
  const start = startDate ?? new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000).toISOString().split("T")[0];

  const data = await queryAnalytics({
    siteUrl,
    startDate: start,
    endDate: end,
    dimensions: ["query", "page"],
    rowLimit: 1000,
  });

  const rows = data.rows ?? [];
  const avgCtr = rows.length > 0
    ? rows.reduce((sum: number, r: any) => sum + (r.ctr ?? 0), 0) / rows.length
    : 0;

  const lowCtr = rows.filter((row: any) => {
    const position = row.position ?? 100;
    const ctr = row.ctr ?? 0;
    return position <= 10 && ctr < avgCtr;
  });

  lowCtr.sort((a: any, b: any) => (a.ctr ?? 0) - (b.ctr ?? 0));

  return {
    dateRange: { startDate: start, endDate: end },
    siteAverageCtr: Math.round(avgCtr * 10000) / 100,
    count: lowCtr.length,
    rows: lowCtr.map((row: any) => ({
      query: row.keys?.[0],
      page: row.keys?.[1],
      clicks: row.clicks,
      impressions: row.impressions,
      ctr: Math.round((row.ctr ?? 0) * 10000) / 100,
      position: Math.round((row.position ?? 0) * 10) / 10,
    })),
  };
}

export async function getPageOpportunities(
  siteUrl?: string,
  startDate?: string,
  endDate?: string
) {
  const now = new Date();
  const end = endDate ?? new Date(now.getTime() - 3 * 24 * 60 * 60 * 1000).toISOString().split("T")[0];
  const start = startDate ?? new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000).toISOString().split("T")[0];

  const data = await queryAnalytics({
    siteUrl,
    startDate: start,
    endDate: end,
    dimensions: ["page", "query"],
    rowLimit: 1000,
  });

  // Group by page
  const pageMap = new Map<string, {
    queries: number;
    nearRankingQueries: number;
    totalImpressions: number;
    totalClicks: number;
    avgPosition: number;
    positionSum: number;
  }>();

  for (const row of data.rows ?? []) {
    const page = row.keys?.[0] ?? "";
    const position = row.position ?? 100;
    const impressions = row.impressions ?? 0;

    if (!pageMap.has(page)) {
      pageMap.set(page, {
        queries: 0,
        nearRankingQueries: 0,
        totalImpressions: 0,
        totalClicks: 0,
        avgPosition: 0,
        positionSum: 0,
      });
    }

    const p = pageMap.get(page)!;
    p.queries++;
    p.totalImpressions += impressions;
    p.totalClicks += row.clicks ?? 0;
    p.positionSum += position;
    if (position >= 8 && position <= 20) {
      p.nearRankingQueries++;
    }
  }

  const pages = Array.from(pageMap.entries()).map(([url, p]) => {
    const avgPos = p.queries > 0 ? p.positionSum / p.queries : 100;
    // Score: near-ranking queries weighted heavily + impression volume
    const score = (p.nearRankingQueries * 3) + (p.totalImpressions / 100);
    return {
      page: url,
      score: Math.round(score * 10) / 10,
      nearRankingQueries: p.nearRankingQueries,
      totalQueries: p.queries,
      totalImpressions: p.totalImpressions,
      totalClicks: p.totalClicks,
      avgPosition: Math.round(avgPos * 10) / 10,
    };
  });

  pages.sort((a, b) => b.score - a.score);

  return {
    dateRange: { startDate: start, endDate: end },
    count: pages.length,
    pages: pages.slice(0, 50),
  };
}

export async function inspectUrl(url: string, siteUrl?: string) {
  const auth = getAuthClient();
  const searchconsole = google.searchconsole({ version: "v1", auth });

  const response = await searchconsole.urlInspection.index.inspect({
    requestBody: {
      inspectionUrl: url,
      siteUrl: siteUrl ?? getDefaultSiteUrl(),
    },
  });

  return response.data;
}
