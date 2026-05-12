// Google Places API (New) client. Used to resolve "what business is at this
// lat/lng" for unknown merchants when location is available.
//
// Requires GOOGLE_PLACES_API_KEY env var. If missing, buildOptionalPlacesClient()
// returns undefined and the recategorize pipeline silently skips this tier.
//
// Pricing: $32 / 1,000 Nearby Search Basic calls. Field mask restricts the
// response to free-tier fields only (displayName, types, location,
// formattedAddress) so we stay on the Basic SKU.

export interface NearbyPlace {
  name: string;
  types: string[];
  lat: number;
  lng: number;
  formattedAddress?: string;
}

export interface NearbyOptions {
  lat: number;
  lng: number;
  radiusMeters?: number;
  maxResults?: number;
}

export interface PlacesClient {
  nearby(opts: NearbyOptions): Promise<NearbyPlace[]>;
}

export interface HttpPlacesOptions {
  apiKey: string;
  fetchFn?: typeof fetch;
}

export class HttpPlacesClient implements PlacesClient {
  private readonly apiKey: string;
  private readonly fetchFn: typeof fetch;

  constructor(opts: HttpPlacesOptions) {
    this.apiKey = opts.apiKey;
    this.fetchFn = opts.fetchFn ?? fetch;
  }

  async nearby(opts: NearbyOptions): Promise<NearbyPlace[]> {
    const radius = opts.radiusMeters ?? 100;
    const maxResults = opts.maxResults ?? 5;

    const res = await this.fetchFn(
      'https://places.googleapis.com/v1/places:searchNearby',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': this.apiKey,
          // Field mask is REQUIRED. Restrict to Basic-SKU fields only.
          'X-Goog-FieldMask':
            'places.displayName,places.types,places.location,places.formattedAddress',
        },
        body: JSON.stringify({
          locationRestriction: {
            circle: {
              center: { latitude: opts.lat, longitude: opts.lng },
              radius,
            },
          },
          maxResultCount: maxResults,
        }),
      },
    );

    if (!res.ok) {
      const body = await res.text().catch(() => '');
      throw new Error(`Places API error ${res.status}: ${body}`);
    }

    const data = (await res.json()) as {
      places?: Array<{
        displayName?: { text?: string };
        types?: string[];
        location?: { latitude?: number; longitude?: number };
        formattedAddress?: string;
      }>;
    };

    return (data.places ?? [])
      .map((p) => ({
        name: p.displayName?.text ?? '',
        types: p.types ?? [],
        lat: p.location?.latitude ?? 0,
        lng: p.location?.longitude ?? 0,
        formattedAddress: p.formattedAddress,
      }))
      .filter((p) => p.name.length > 0);
  }
}

export function buildOptionalPlacesClient(): PlacesClient | undefined {
  const key = process.env['GOOGLE_PLACES_API_KEY'];
  if (!key) return undefined;
  return new HttpPlacesClient({ apiKey: key });
}
