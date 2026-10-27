import Foundation

/// Reference vocabulary for label parsing. These are naming facts (which
/// region is in which country), not wine-specific claims.
enum WineLexicon {
    struct Grape: Sendable {
        let name: String
        let color: WineType
    }

    struct Place: Sendable {
        let name: String
        let region: String
        let country: String
        var style: WineType? = nil
    }

    static let grapes: [Grape] = [
        .init(name: "Cabernet Sauvignon", color: .red), .init(name: "Cabernet Franc", color: .red),
        .init(name: "Merlot", color: .red), .init(name: "Pinot Noir", color: .red), .init(name: "Syrah", color: .red),
        .init(name: "Shiraz", color: .red), .init(name: "Malbec", color: .red), .init(name: "Grenache", color: .red),
        .init(name: "Garnacha", color: .red), .init(name: "Tempranillo", color: .red), .init(name: "Sangiovese", color: .red),
        .init(name: "Nebbiolo", color: .red), .init(name: "Zinfandel", color: .red), .init(name: "Primitivo", color: .red),
        .init(name: "Barbera", color: .red), .init(name: "Petit Verdot", color: .red), .init(name: "Mourvèdre", color: .red),
        .init(name: "Carménère", color: .red), .init(name: "Gamay", color: .red), .init(name: "Pinotage", color: .red),
        .init(name: "Touriga Nacional", color: .red), .init(name: "Aglianico", color: .red), .init(name: "Montepulciano", color: .red),
        .init(name: "Corvina", color: .red), .init(name: "Nero d'Avola", color: .red), .init(name: "Petite Sirah", color: .red),
        .init(name: "Cinsault", color: .red), .init(name: "Carignan", color: .red), .init(name: "Dolcetto", color: .red),
        .init(name: "Chardonnay", color: .white), .init(name: "Sauvignon Blanc", color: .white), .init(name: "Riesling", color: .white),
        .init(name: "Pinot Grigio", color: .white), .init(name: "Pinot Gris", color: .white), .init(name: "Chenin Blanc", color: .white),
        .init(name: "Gewürztraminer", color: .white), .init(name: "Viognier", color: .white), .init(name: "Sémillon", color: .white),
        .init(name: "Albariño", color: .white), .init(name: "Grüner Veltliner", color: .white), .init(name: "Moscato", color: .white),
        .init(name: "Muscat", color: .white), .init(name: "Vermentino", color: .white), .init(name: "Rolle", color: .white),
        .init(name: "Marsanne", color: .white), .init(name: "Roussanne", color: .white), .init(name: "Verdejo", color: .white),
        .init(name: "Garganega", color: .white), .init(name: "Pinot Blanc", color: .white), .init(name: "Torrontés", color: .white),
        .init(name: "Ribolla Gialla", color: .white), .init(name: "Fiano", color: .white), .init(name: "Assyrtiko", color: .white),
        .init(name: "Furmint", color: .white), .init(name: "Glera", color: .white), .init(name: "Melon de Bourgogne", color: .white),
    ]

    static let places: [Place] = [
        // France
        .init(name: "Bordeaux", region: "Bordeaux", country: "France"),
        .init(name: "Margaux", region: "Bordeaux", country: "France", style: .red),
        .init(name: "Pauillac", region: "Bordeaux", country: "France", style: .red),
        .init(name: "Saint-Julien", region: "Bordeaux", country: "France", style: .red),
        .init(name: "Saint-Estèphe", region: "Bordeaux", country: "France", style: .red),
        .init(name: "Pessac-Léognan", region: "Bordeaux", country: "France"),
        .init(name: "Saint-Émilion", region: "Bordeaux", country: "France", style: .red),
        .init(name: "Pomerol", region: "Bordeaux", country: "France", style: .red),
        .init(name: "Sauternes", region: "Bordeaux", country: "France", style: .dessert),
        .init(name: "Médoc", region: "Bordeaux", country: "France", style: .red),
        .init(name: "Burgundy", region: "Burgundy", country: "France"),
        .init(name: "Bourgogne", region: "Burgundy", country: "France"),
        .init(name: "Chablis", region: "Burgundy", country: "France", style: .white),
        .init(name: "Puligny-Montrachet", region: "Burgundy", country: "France", style: .white),
        .init(name: "Meursault", region: "Burgundy", country: "France", style: .white),
        .init(name: "Gevrey-Chambertin", region: "Burgundy", country: "France", style: .red),
        .init(name: "Vosne-Romanée", region: "Burgundy", country: "France", style: .red),
        .init(name: "Pommard", region: "Burgundy", country: "France", style: .red),
        .init(name: "Beaujolais", region: "Beaujolais", country: "France", style: .red),
        .init(name: "Champagne", region: "Champagne", country: "France", style: .sparkling),
        .init(name: "Côtes du Rhône", region: "Rhône", country: "France"),
        .init(name: "Châteauneuf-du-Pape", region: "Rhône", country: "France"),
        .init(name: "Hermitage", region: "Rhône", country: "France"),
        .init(name: "Côte-Rôtie", region: "Rhône", country: "France", style: .red),
        .init(name: "Sancerre", region: "Loire", country: "France"),
        .init(name: "Vouvray", region: "Loire", country: "France", style: .white),
        .init(name: "Côtes de Provence", region: "Provence", country: "France"),
        .init(name: "Provence", region: "Provence", country: "France"),
        .init(name: "Alsace", region: "Alsace", country: "France"),
        // Italy
        .init(name: "Barolo", region: "Piedmont", country: "Italy", style: .red),
        .init(name: "Barbaresco", region: "Piedmont", country: "Italy", style: .red),
        .init(name: "Piemonte", region: "Piedmont", country: "Italy"),
        .init(name: "Chianti Classico", region: "Tuscany", country: "Italy", style: .red),
        .init(name: "Chianti", region: "Tuscany", country: "Italy", style: .red),
        .init(name: "Brunello di Montalcino", region: "Tuscany", country: "Italy", style: .red),
        .init(name: "Bolgheri", region: "Tuscany", country: "Italy"),
        .init(name: "Toscana", region: "Tuscany", country: "Italy"),
        .init(name: "Amarone della Valpolicella", region: "Veneto", country: "Italy", style: .red),
        .init(name: "Valpolicella", region: "Veneto", country: "Italy", style: .red),
        .init(name: "Prosecco", region: "Veneto", country: "Italy", style: .sparkling),
        .init(name: "Soave", region: "Veneto", country: "Italy", style: .white),
        .init(name: "Etna", region: "Sicily", country: "Italy"),
        .init(name: "Sicilia", region: "Sicily", country: "Italy"),
        .init(name: "Alto Adige", region: "Trentino-Alto Adige", country: "Italy"),
        .init(name: "Friuli", region: "Friuli-Venezia Giulia", country: "Italy"),
        // Spain & Portugal
        .init(name: "Rioja", region: "Rioja", country: "Spain"),
        .init(name: "Ribera del Duero", region: "Ribera del Duero", country: "Spain", style: .red),
        .init(name: "Priorat", region: "Priorat", country: "Spain", style: .red),
        .init(name: "Rías Baixas", region: "Rías Baixas", country: "Spain", style: .white),
        .init(name: "Cava", region: "Penedès", country: "Spain", style: .sparkling),
        .init(name: "Douro", region: "Douro", country: "Portugal"),
        .init(name: "Porto", region: "Douro", country: "Portugal", style: .fortified),
        .init(name: "Vinho Verde", region: "Minho", country: "Portugal", style: .white),
        // Germany & Austria
        .init(name: "Mosel", region: "Mosel", country: "Germany"),
        .init(name: "Rheingau", region: "Rheingau", country: "Germany"),
        .init(name: "Pfalz", region: "Pfalz", country: "Germany"),
        .init(name: "Wachau", region: "Wachau", country: "Austria"),
        // New World
        .init(name: "Napa Valley", region: "Napa Valley", country: "USA"),
        .init(name: "Sonoma Coast", region: "Sonoma Coast", country: "USA"),
        .init(name: "Sonoma County", region: "Sonoma", country: "USA"),
        .init(name: "Russian River Valley", region: "Sonoma", country: "USA"),
        .init(name: "Paso Robles", region: "Central Coast", country: "USA"),
        .init(name: "Santa Cruz Mountains", region: "Santa Cruz Mountains", country: "USA"),
        .init(name: "Willamette Valley", region: "Willamette Valley", country: "USA"),
        .init(name: "Columbia Valley", region: "Washington", country: "USA"),
        .init(name: "Oakville", region: "Napa Valley", country: "USA"),
        .init(name: "Rutherford", region: "Napa Valley", country: "USA"),
        .init(name: "Mendoza", region: "Mendoza", country: "Argentina"),
        .init(name: "Maipo Valley", region: "Maipo Valley", country: "Chile"),
        .init(name: "Colchagua", region: "Colchagua", country: "Chile"),
        .init(name: "Barossa Valley", region: "Barossa Valley", country: "Australia"),
        .init(name: "McLaren Vale", region: "McLaren Vale", country: "Australia"),
        .init(name: "Margaret River", region: "Margaret River", country: "Australia"),
        .init(name: "South Australia", region: "South Australia", country: "Australia"),
        .init(name: "Marlborough", region: "Marlborough", country: "New Zealand"),
        .init(name: "Central Otago", region: "Central Otago", country: "New Zealand"),
        .init(name: "Stellenbosch", region: "Stellenbosch", country: "South Africa"),
    ]

    /// Folded phrases that state a country of origin.
    static let countryPhrases: [(String, String)] = [
        ("product of france", "France"), ("produce of france", "France"), ("vin de france", "France"), ("france", "France"),
        ("product of italy", "Italy"), ("prodotto in italia", "Italy"), ("italia", "Italy"), ("italy", "Italy"),
        ("product of spain", "Spain"), ("espana", "Spain"), ("spain", "Spain"),
        ("portugal", "Portugal"), ("germany", "Germany"), ("deutschland", "Germany"), ("austria", "Austria"), ("osterreich", "Austria"),
        ("new zealand", "New Zealand"), ("australia", "Australia"), ("argentina", "Argentina"), ("chile", "Chile"),
        ("south africa", "South Africa"), ("california", "USA"), ("oregon", "USA"), ("washington", "USA"), ("usa", "USA"),
        ("greece", "Greece"), ("hungary", "Hungary"),
    ]
}
