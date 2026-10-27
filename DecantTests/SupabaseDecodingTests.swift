import Foundation
import Testing
@testable import Decant

/// Decodes JSON shaped exactly like PostgREST responses, to catch key-mapping bugs
/// (the shared decoder converts snake_case automatically).
@Suite("Supabase row decoding")
struct SupabaseDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try SupabaseCoding.decoder.decode(T.self, from: Data(json.utf8))
    }

    let id = "6b1e0f1a-0000-4000-8000-000000000001"

    @Test func reviewAndNoteRows() throws {
        let reviews = try decode([ReviewRead].self, #"[{"entry_id":"\#(id)","user_id":"\#(id)","body":"Lovely"}]"#)
        #expect(reviews.first?.body == "Lovely")
        let notes = try decode([PrivateNoteRead].self, #"[{"entry_id":"\#(id)","user_id":"\#(id)","notes":"secret"}]"#)
        #expect(notes.first?.notes == "secret")
    }

    @Test func tastingRowWithDateColumn() throws {
        let rows = try decode([TastingRow].self, #"""
        [{"id":"\#(id)","user_id":"\#(id)","vintage_id":"\#(id)","rating":4.5,"consumed_on":"2026-10-20","location":null,
          "occasion":"Dinner","drink_again":true,"is_favorite":false,"visibility":"friends","tagged_user_ids":[],
          "photo_paths":[],"created_at":"2026-10-27T21:40:12.123456+00:00"}]
        """#)
        #expect(rows.first?.rating == 4.5)
        #expect(rows.first?.visibility == .friends)
    }

    @Test func statsProfileBottleAndCatalogRows() throws {
        _ = try decode([EntryStatsRow].self, #"[{"entry_id":"\#(id)","like_count":2,"comment_count":0,"liked_by_me":true}]"#)
        let profile = try decode(ProfileRow.self, #"""
        {"id":"\#(id)","username":"appreview","display_name":"App Review","avatar_url":null,"bio":null,"is_private":false,
         "favorite_types":["red"],"default_visibility":"public","cellar_finish":"walnut","cellar_sort":"manual",
         "created_at":"2026-10-27T21:40:12+00:00","updated_at":"2026-10-27T21:40:12+00:00","terms_accepted_at":null}
        """#)
        #expect(profile.profile.displayName == "App Review")
        _ = try decode([BottleRow].self, #"""
        [{"id":"\#(id)","vintage_id":"\#(id)","quantity":2,"consumed_count":0,"purchase_price":750.00,"currency":"USD",
          "purchase_date":"2026-10-27","storage_location":"Wine fridge","collection_id":null,"added_at":"2026-10-27T21:40:12.5+00:00"}]
        """#)
        let wine = try decode(WineCatalogRow.self, #"""
        {"id":"\#(id)","product_id":"\#(id)","name":"Château Margaux","type":"red","country":"France","region":"Bordeaux",
         "appellation":"Margaux","grapes":["Cabernet Sauvignon"],"grape_percentages":null,"year":2015,"bottle_size_ml":750,
         "abv":null,"price_estimate":750.00,"currency":"USD","drink_from":2030,"drink_until":2065,"label_image_path":null,
         "bottle_image_path":null,"facts_source":"editorial","winery_id":"\#(id)","winery_name":"Château Margaux",
         "winery_country":"France","winery_region":"Bordeaux","winery_founded_year":null,"winery_story":"First Growth.",
         "winery_practices":[],"winery_highlights":[],"winery_source":"editorial",
         "characteristics":{"sweetness":0.05,"acidity":0.65,"body":0.85,"tannin":0.8,"fruitiness":0.65,"flavors":["Cassis"],
           "tasting_notes":"Perfumed.","serve_min_c":16,"serve_max_c":18,"decant_minutes":90,"aging_years":40,"source":"editorial"},
         "pairings":["Roast lamb"],"avg_rating":4.75,"ratings_count":2,"created_at":"2026-10-27T21:40:12+00:00"}
        """#)
        #expect(wine.wine.characteristics?.servingTempC == 16...18)
    }
}
