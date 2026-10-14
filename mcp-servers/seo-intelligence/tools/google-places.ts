const PLACES_BASE = "https://maps.googleapis.com/maps/api/place";

function getApiKey(): string {
  const key = process.env.GOOGLE_API_KEY;
  if (!key) throw new Error("GOOGLE_API_KEY not configured");
  return key;
}

export interface PlaceSearchResult {
  name: string;
  address: string;
  place_id: string;
  rating?: number;
  user_ratings_total?: number;
  types: string[];
  website?: string;
  business_status?: string;
}

export async function placesTextSearch(
  query: string,
  location?: string
): Promise<PlaceSearchResult[]> {
  const params = new URLSearchParams({
    query,
    key: getApiKey(),
  });
  if (location) params.set("location", location);

  const response = await fetch(`${PLACES_BASE}/textsearch/json?${params}`);
  if (!response.ok) {
    throw new Error(`Places API HTTP ${response.status}: ${await response.text()}`);
  }

  const data = await response.json();
  if (data.status !== "OK" && data.status !== "ZERO_RESULTS") {
    throw new Error(`Places API error: ${data.status} — ${data.error_message ?? ""}`);
  }

  return (data.results ?? []).map((r: any) => ({
    name: r.name,
    address: r.formatted_address ?? "",
    place_id: r.place_id,
    rating: r.rating,
    user_ratings_total: r.user_ratings_total,
    types: r.types ?? [],
    business_status: r.business_status,
  }));
}

export interface PlaceDetails {
  name: string;
  address: string;
  phone?: string;
  website?: string;
  rating?: number;
  reviews_count?: number;
  types: string[];
  url?: string;
  opening_hours?: string[];
  reviews?: { rating: number; text: string; time: string }[];
}

export async function placeDetails(placeId: string): Promise<PlaceDetails> {
  const fields = [
    "name",
    "formatted_address",
    "formatted_phone_number",
    "website",
    "rating",
    "user_ratings_total",
    "types",
    "url",
    "opening_hours",
    "reviews",
  ].join(",");

  const params = new URLSearchParams({
    place_id: placeId,
    fields,
    key: getApiKey(),
  });

  const response = await fetch(`${PLACES_BASE}/details/json?${params}`);
  if (!response.ok) {
    throw new Error(`Places API HTTP ${response.status}: ${await response.text()}`);
  }

  const data = await response.json();
  if (data.status !== "OK") {
    throw new Error(`Places API error: ${data.status} — ${data.error_message ?? ""}`);
  }

  const r = data.result;
  return {
    name: r.name,
    address: r.formatted_address ?? "",
    phone: r.formatted_phone_number,
    website: r.website,
    rating: r.rating,
    reviews_count: r.user_ratings_total,
    types: r.types ?? [],
    url: r.url,
    opening_hours: r.opening_hours?.weekday_text,
    reviews: r.reviews?.slice(0, 5).map((rev: any) => ({
      rating: rev.rating,
      text: rev.text,
      time: rev.relative_time_description,
    })),
  };
}
