// Google Places type → our V1 Category. Pure static mapping; replaces the
// Groq round-trip for location-based recategorization.
//
// Places returns a `types` array per result, ordered most-specific-first
// (e.g. ["italian_restaurant", "restaurant", "food", "point_of_interest"]).
// We walk the array, return the first match. If nothing matches, we return
// null and the caller leaves the transaction for human review.
//
// Reference: https://developers.google.com/maps/documentation/places/web-service/place-types

/** Confidence we publish when a Places type maps cleanly to a category. */
export const PLACES_TYPE_CONFIDENCE = 0.97;

/** Confidence for catch-all parent types like `store` or `food`. */
export const PLACES_TYPE_CONFIDENCE_WEAK = 0.88;

const STRONG_TYPE_TO_CATEGORY: Record<string, string> = {
  // ---- Food ------------------------------------------------------------
  restaurant: 'Food',
  fast_food_restaurant: 'Food',
  cafe: 'Food',
  coffee_shop: 'Food',
  bakery: 'Food',
  bar: 'Food',
  pub: 'Food',
  meal_takeaway: 'Food',
  meal_delivery: 'Food',
  ice_cream_shop: 'Food',
  dessert_shop: 'Food',
  // Cuisine-specific restaurants — Places sometimes returns these as the
  // primary type and only the cuisine name. Map every common one.
  american_restaurant: 'Food',
  italian_restaurant: 'Food',
  japanese_restaurant: 'Food',
  chinese_restaurant: 'Food',
  indian_restaurant: 'Food',
  korean_restaurant: 'Food',
  thai_restaurant: 'Food',
  mexican_restaurant: 'Food',
  french_restaurant: 'Food',
  greek_restaurant: 'Food',
  vietnamese_restaurant: 'Food',
  vegan_restaurant: 'Food',
  vegetarian_restaurant: 'Food',
  steak_house: 'Food',
  pizza_restaurant: 'Food',
  ramen_restaurant: 'Food',
  sandwich_shop: 'Food',
  sushi_restaurant: 'Food',
  seafood_restaurant: 'Food',
  barbecue_restaurant: 'Food',
  hamburger_restaurant: 'Food',
  juice_shop: 'Food',
  brunch_restaurant: 'Food',
  breakfast_restaurant: 'Food',
  buffet_restaurant: 'Food',

  // ---- Groceries -------------------------------------------------------
  grocery_store: 'Shopping',
  supermarket: 'Shopping',
  convenience_store: 'Shopping',
  food_store: 'Shopping',
  butcher_shop: 'Shopping',
  market: 'Shopping',

  // ---- Entertainment ---------------------------------------------------
  movie_theater: 'Entertainment',
  amusement_park: 'Entertainment',
  night_club: 'Entertainment',
  casino: 'Entertainment',
  art_gallery: 'Entertainment',
  museum: 'Entertainment',
  zoo: 'Entertainment',
  stadium: 'Entertainment',
  bowling_alley: 'Entertainment',
  performing_arts_theater: 'Entertainment',
  concert_hall: 'Entertainment',
  comedy_club: 'Entertainment',
  arcade: 'Entertainment',
  karaoke: 'Entertainment',
  aquarium: 'Entertainment',
  water_park: 'Entertainment',
  amusement_center: 'Entertainment',

  // ---- Travel ----------------------------------------------------------
  airport: 'Travel',
  bus_station: 'Travel',
  train_station: 'Travel',
  subway_station: 'Travel',
  light_rail_station: 'Travel',
  transit_station: 'Travel',
  taxi_stand: 'Travel',
  car_rental: 'Travel',
  gas_station: 'Travel',
  hotel: 'Travel',
  lodging: 'Travel',
  motel: 'Travel',
  resort_hotel: 'Travel',
  inn: 'Travel',
  guest_house: 'Travel',
  hostel: 'Travel',
  rest_stop: 'Travel',
  truck_stop: 'Travel',
  ferry_terminal: 'Travel',
};

const WEAK_TYPE_TO_CATEGORY: Record<string, string> = {
  // Generic catch-alls — confidence is high enough to auto-tag but we
  // surface a separate constant so future callers can choose to threshold
  // differently.
  food: 'Food',
  restaurant_or_cafe: 'Food',
};

export interface PlacesTypeMatch {
  /** Our V1 category name (matches the `Category.name` row in the DB). */
  category: string;
  /** 0..1 confidence. Strong matches are PLACES_TYPE_CONFIDENCE. */
  confidence: number;
  /** The exact Places type string that triggered the match. */
  matchedType: string;
}

/**
 * Walk the candidate's `types` array and return the first recognized mapping.
 * Returns `null` when no type maps to a V1 category.
 */
export function mapPlacesTypesToCategory(
  types: ReadonlyArray<string>,
): PlacesTypeMatch | null {
  // Pass 1 — strong types (most specific wins because they appear first).
  for (const type of types) {
    const category = STRONG_TYPE_TO_CATEGORY[type];
    if (category) {
      return {
        category,
        confidence: PLACES_TYPE_CONFIDENCE,
        matchedType: type,
      };
    }
  }
  // Pass 2 — weak / catch-all types only if no strong type matched.
  for (const type of types) {
    const category = WEAK_TYPE_TO_CATEGORY[type];
    if (category) {
      return {
        category,
        confidence: PLACES_TYPE_CONFIDENCE_WEAK,
        matchedType: type,
      };
    }
  }
  return null;
}
