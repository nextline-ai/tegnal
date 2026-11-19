import XCTest
import UIKit
@testable import TEGNAL

final class KeyedCatalogTests: XCTestCase {
    private let keys = ["manga.site_address", "manga.resolved_data_host", "manga.resolved_cdn_host", "manga.resolved_backend_site",
                        "manga.resolved_protocol", "manga.resolved_media_hosts", "manga.resolved_preview_base", "manga.resolved_api",
                        "manga.resolved_login", "manga.account_site", "manga.account_host", "manga.account_required"]
    private var saved: [String: Any] = [:]
    override func setUp() {
        super.setUp()
        for key in keys { saved[key] = MangaUrls.preferences.object(forKey: key) }
        for key in keys { MangaUrls.preferences.removeObject(forKey: key) }
        MangaUrls.preferences.set("keyed.example", forKey: "manga.site_address")
        GalleryKeys.shared.removeAll()
        SiteAccount.signOut()
    }
    override func tearDown() {
        KeyedFixtureProtocol.install(nil)
        SiteAccount.signOut()
        GalleryKeys.shared.removeAll()
        for key in keys { MangaUrls.preferences.set(saved[key], forKey: key) }
        super.tearDown()
    }
    private func fixture() -> KeyedFixture {
        let fixture = KeyedFixture()
        KeyedFixtureProtocol.install(fixture)
        return fixture
    }

    func testListingResolvesTheProtocolAndFollowsTheCursor() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        let first = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 3)
        XCTAssertEqual(first.ids, [3002, 3001, 3000])
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(MangaUrls.backend, .keyed)
        XCTAssertEqual(MangaUrls.keyedAPI?.absoluteString, "https://api.keyed.example/api.php")
        XCTAssertEqual(MangaUrls.signInURL?.absoluteString, "https://keyed.example/bounce_login.php?b=d&bt=1")
        XCTAssertEqual(MangaUrls.galleryUrl(for: 3000), "https://keyed.example/g/3000/\(KeyedFixture.key(3000))/")
        XCTAssertEqual(GallerySort.available, [.latest, .today])
        XCTAssertTrue(GalleryCategory.available.contains("western"))

        let second = try await source.list(GalleryQuery(language: "all"), offset: 3, count: 3)
        XCTAssertEqual(second.ids, [2999, 2998])
        XCTAssertFalse(second.hasMore)
        XCTAssertTrue(fixture.requests.contains { $0.query?.contains("next=2999") == true })

        let preview = try XCTUnwrap(source.cachedPreview(3000))
        XCTAssertEqual(preview.title, "Sample 3000", "A translation leads with its translated title")
        XCTAssertEqual(source.cachedPreview(2999)?.title, "原題 2999", "A work still in Japanese leads with its original title")
        XCTAssertEqual(source.cachedPreview(3001)?.type, "manga")
        XCTAssertEqual(preview.artists, ["sample artist"])
        XCTAssertEqual(preview.language, "korean")
        XCTAssertTrue(preview.tags.contains("series:sample series"))
        XCTAssertTrue(preview.tags.contains("tag:sample tag"))
        XCTAssertEqual(fixture.count(path: "/api.php"), 2, "Each listing page reads its details in one batch")
    }

    func testSearchesSendTagsCategoriesAndExclusionsInTheSiteSpelling() async throws {
        let query = GalleryQuery(language: "korean", artist: "sample artist", text: "female:big_breasts series:sample -tag:excluded type:manga")
        let url = try KeyedCatalogSource.searchURL(query, site: "https://keyed.example/", categories: try KeyedCatalogSource.selectedCategories(query),
                                                   language: "korean", next: "2999")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "f_search" }?.value,
                       #"female:"big breasts$" parody:"sample$" language:"korean$" artist:"sample artist$" -other:"excluded$""#)
        XCTAssertEqual(items.first { $0.name == "f_cats" }?.value, String(1023 & ~4))
        XCTAssertEqual(items.first { $0.name == "next" }?.value, "2999")
        XCTAssertEqual(try URLComponents(url: KeyedCatalogSource.searchURL(GalleryQuery(language: "all"), site: "https://keyed.example/",
                                                                        categories: KeyedCatalogSource.allCategories, language: nil, next: nil),
                                         resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "f_cats", value: "0")],
                       "Every category is asked for outright, so an account's default exclusions don't narrow the list")

        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        let filtered = try await source.list(GalleryQuery(language: "all", text: "-female:marked_tag"), offset: 0, count: 5)
        XCTAssertFalse(filtered.ids.contains(3002), "Exclusions also apply to rows the site still returned")
        let manga = try await source.list(GalleryQuery(language: "all", text: "type:manga"), offset: 0, count: 5)
        XCTAssertEqual(manga.ids, [3001])
    }

    func testWorkPagesPreviewsAndReaderImages() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        _ = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 3)
        let gallery = try await source.gallery(3000)
        XCTAssertEqual(gallery.pages.count, 3)
        XCTAssertEqual(gallery.pages[1].name, "two.jpg")
        XCTAssertEqual(gallery.pages[0].thumbnailURL?.absoluteString, "https://covers.example/3000.jpg", "The first page shows the cover")

        let cover = try await source.image(gallery.pages[0], galleryID: 3000, thumbnail: true)
        XCTAssertEqual(cover, fixture.image)
        let tileData = try await source.image(gallery.pages[1], galleryID: 3000, thumbnail: true)
        let tile = try XCTUnwrap(UIImage(data: tileData))
        XCTAssertEqual(tile.size, CGSize(width: 100, height: 150), "A page preview is cut out of the sheet of previews")
        _ = try await source.image(gallery.pages[0], galleryID: 3000, thumbnail: false)
        XCTAssertEqual(fixture.count(path: "/3000-0.png"), 1, "Tiles of one sheet share one download")

        _ = try await source.image(gallery.pages[2], galleryID: 3000, thumbnail: true)
        XCTAssertTrue(fixture.requests.contains { $0.path == "/g/3000/\(KeyedFixture.key(3000))" && $0.query == "p=1" },
                      "Pages past the first sheet are read when they are needed")

        fixture.failFirstNode = true
        let page = try await source.image(gallery.pages[1], galleryID: 3000, thumbnail: false)
        XCTAssertEqual(page, fixture.image)
        XCTAssertTrue(fixture.requests.contains { $0.host == "node2.volunteer.example" && $0.port == 8440 }, "A failed host is replaced by another one")
        XCTAssertTrue(fixture.requests.contains { $0.query == "nl=alt-2" })
    }

    func testImageAllowanceNoticeIsReportedInsteadOfShown() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        let gallery = try await source.gallery(3000)
        fixture.allowanceUsed = true
        do {
            _ = try await source.image(gallery.pages[1], galleryID: 3000, thumbnail: false)
            XCTFail("The notice image must not be shown as a page")
        } catch ContentError.imageLimit { }
    }

    func testImageHostsAnsweringInWordsReportTheAllowanceOrTheBan() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        let gallery = try await source.gallery(3000)
        fixture.textAnswer = "You have reached the image limit, and do not have sufficient GP to buy a download quota."
        do {
            _ = try await source.image(gallery.pages[1], galleryID: 3000, thumbnail: false)
            XCTFail("The allowance notice must be reported, not read as a broken image")
        } catch ContentError.imageLimit { }
        XCTAssertFalse(fixture.requests.contains { $0.query?.hasPrefix("nl=") == true }, "The notice is the site's answer, so no other host is asked")
        XCTAssertEqual(fixture.count(path: "/s/2222222222/3000-2"), 1)

        fixture.textAnswer = "Your IP address has been temporarily banned for excessive pageloads which indicates that you are using automated mirroring/harvesting software. The ban expires in 59 minutes and 48 seconds"
        do {
            _ = try await source.image(gallery.pages[1], galleryID: 3000, thumbnail: false)
            XCTFail("The ban must be reported, not read as a broken image")
        } catch ContentError.temporarilyBlocked { }
        XCTAssertFalse(fixture.requests.contains { $0.query?.hasPrefix("nl=") == true })

        XCTAssertNil(KeyedCatalogSource.textNotice(Data("<html><body>An error has occurred.</body></html>".utf8), mimeType: "text/html"),
                     "Other words from a host leave the usual retry on another host")
        XCTAssertNil(KeyedCatalogSource.textNotice(Data("You have reached the image limit".utf8), mimeType: "image/webp"), "Image bytes are never read as words")
    }

    func testNumberLookupsIgnoreTheAccountsOwnFilters() async throws {
        let url = try XCTUnwrap(KeyedCatalogSource.keySearchURL(2990, site: "https://keyed.example/"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }),
                       ["f_search": "gid:2990", "f_cats": "0", "advsearch": "1", "f_sfl": "on", "f_sfu": "on", "f_sft": "on"],
                       "Hidden languages, uploaders, tags and default categories must not hide the work being looked up")

        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        _ = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 1)
        GalleryKeys.shared.removeAll()
        _ = try await source.gallery(2990)
        let lookup = try XCTUnwrap(fixture.requests.first { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "f_search", value: "gid:2990")) == true })
        XCTAssertEqual(URLComponents(url: lookup, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "f_sfl" }?.value, "on")
    }

    func testCardsReadWorksFromTheDetailsEndpointWithoutOpeningThem() async throws {
        let fixture = fixture()
        _ = try await MangaContentSource(transport: fixture.transport()).list(GalleryQuery(language: "all"), offset: 0, count: 3)
        // A source whose cached details are gone, as after the system emptied its caches.
        let source = MangaContentSource(transport: fixture.transport())
        XCTAssertNil(source.cachedPreview(3000))
        let detailsBefore = fixture.count(path: "/api.php")
        let workPagesBefore = fixture.requests.filter { $0.path.hasPrefix("/g/") }.count
        async let first = source.preview(3000)
        async let second = source.preview(3001)
        async let third = source.preview(3002)
        let works = try await [first, second, third]
        XCTAssertEqual(works.map(\.id), [3000, 3001, 3002])
        XCTAssertEqual(works[0].pageCount, 3)
        XCTAssertEqual(works[0].uploader, "uploader & 3000", "The uploader comes with the details, decoded")
        XCTAssertEqual(works[0].pages.first?.thumbnailURL?.absoluteString, "https://covers.example/3000.jpg")
        XCTAssertEqual(fixture.count(path: "/api.php") - detailsBefore, 1, "Cards asking together share one details request")
        XCTAssertEqual(fixture.requests.filter { $0.path.hasPrefix("/g/") }.count, workPagesBefore, "A card never opens the work's own page")
        XCTAssertNotNil(source.cachedPreview(3001))
    }

    func testAFailedDetailsRequestIsAskedOnceMore() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        fixture.failDetails = 1
        _ = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 3)
        XCTAssertNotNil(source.cachedPreview(3000), "Details lost to one failed request come with the next")
        XCTAssertEqual(fixture.count(path: "/api.php"), 2)
    }

    func testARememberedKeyTheSiteRefusesIsLookedUpAgain() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        _ = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 1)
        GalleryKeys.shared.remember(2990, key: "ffffffffff")
        let gallery = try await source.gallery(2990)
        XCTAssertEqual(gallery.id, 2990)
        XCTAssertEqual(GalleryKeys.shared.key(for: 2990), KeyedFixture.key(2990), "The key the site accepts replaces the refused one")
        XCTAssertTrue(fixture.requests.contains { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "f_search", value: "gid:2990")) == true })
    }

    func testPageLoadsOnOneWebsiteArePacedAndOtherWebsitesAreNotHeldUp() async throws {
        let pacer = PagePacer(burst: 2, interval: .milliseconds(100))
        let clock = ContinuousClock()
        let burst = try await clock.measure { for _ in 0..<2 { try await pacer.wait(host: "a.example") } }
        XCTAssertLessThan(burst, .milliseconds(50), "A short burst goes at once")
        let paced = try await clock.measure { for _ in 0..<2 { try await pacer.wait(host: "a.example") } }
        XCTAssertGreaterThanOrEqual(paced, .milliseconds(180), "Then one page load per interval")
        let other = try await clock.measure { try await pacer.wait(host: "b.example") }
        XCTAssertLessThan(other, .milliseconds(50))
    }

    func testFavoritesKeepTheirNoteAndARefusedChangeIsReported() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        _ = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 1)
        let cookies = [("app_member_id", "42"), ("app_pass_hash", "secret")].map {
            HTTPCookie(properties: [.domain: ".keyed.example", .path: "/", .name: $0.0, .value: $0.1])!
        }
        XCTAssertTrue(SiteAccount.signIn(with: cookies, host: MangaUrls.configuredHost))
        fixture.favoriteNote = "read later &amp; 다시"
        try await source.setAccountFavorite(3000, saved: true, category: 2)
        XCTAssertEqual(fixture.favoriteForms.last, "favcat=2&favnote=read+later+%26+%EB%8B%A4%EC%8B%9C&apply=Add+to+Favorites&update=1",
                       "Moving a favorite sends its note back so the site keeps it")
        fixture.favoriteReply = "Key missing, or incorrect key provided."
        do {
            try await source.setAccountFavorite(3000, saved: false)
            XCTFail("A change the site refused must not pass as done")
        } catch ContentError.galleryNotFound { }
        XCTAssertEqual(KeyedCatalogSource.favoriteNote(in: #"<textarea name="favnote">a &lt;b&gt;</textarea>"#), "a <b>")
    }

    func testViewerAccountsKeepThePreviewsTheirWorkPageShows() {
        let detail = String(decoding: KeyedFixture.viewerDetail(3000), as: UTF8.self)
        let shown = KeyedCatalogSource.viewerPreviews(in: detail, galleryID: 3000)
        XCTAssertEqual(shown[1], KeyedCatalogSource.Thumb(url: URL(string: "https://sheets.example/3000-0.png")!, crop: CGRect(x: 100, y: 0, width: 100, height: 150)))
        let viewer = #"<script>var imagelist = [{"n":"one.jpg","k":"aaaaaaaaaa","t":"(https://sheets.example/3000-0.png) -0px 0"},{"n":"two.jpg","k":"bbbbbbbbbb","t":"https:\/\/sheets.example\/large-2.jpg"}];</script>"#
        let entries = KeyedCatalogSource.viewerEntries(in: viewer, previews: shown)
        XCTAssertEqual(entries[0]?.thumb, shown[0], "A listed preview that is not a plain address takes the work page's")
        XCTAssertEqual(entries[1]?.thumb?.url.absoluteString, "https://sheets.example/large-2.jpg", "A plain listed address still wins")
    }

    func testViewerAndPageLinksOpenInTheApp() {
        let key = KeyedFixture.key(3000)
        XCTAssertEqual(GalleryIDParser.parse("https://keyed.example/mpv/3000/\(key)/#page2"), [3000])
        XCTAssertEqual(GalleryKeys.shared.key(for: 3000), key, "A viewer link carries the work's key")
        XCTAssertEqual(GalleryIDParser.parse("see https://keyed.example/s/abcdef1234/3001-5"), [3001])
        XCTAssertNil(GalleryKeys.shared.key(for: 3001), "A page link's key belongs to the page, not the work")
        XCTAssertEqual(ContentRoute.initial("https://keyed.example/mpv/3000/\(key)/"), .gallery(3000))
        XCTAssertEqual(ContentRoute.initial("https://keyed.example/s/abcdef1234/3001-5"), .reader(3001, 5))
    }

    // MARK: Votes, comments, archives, originals and settings profiles

    private func signIn() {
        let cookies = [("app_member_id", "42"), ("app_pass_hash", "secret")].map {
            HTTPCookie(properties: [.domain: ".keyed.example", .path: "/", .name: $0.0, .value: $0.1])!
        }
        XCTAssertTrue(SiteAccount.signIn(with: cookies, host: MangaUrls.configuredHost))
    }

    func testWorkPagesShowTagVotesTheCommentFormAndTheArchive() throws {
        let extras = KeyedWorkPage.extras(from: String(decoding: KeyedFixture.detail(3000, page: 0), as: UTF8.self))
        XCTAssertEqual(extras.tagVotes, [WorkTagVote(tag: "female:sample tag", vote: 1), WorkTagVote(tag: "parody:sample series", vote: 0)])
        XCTAssertEqual(extras.tagVotes[1].localNamespace, "series")
        XCTAssertTrue(extras.canComment)
        XCTAssertTrue(extras.canRate)
        XCTAssertEqual(extras.archiveURL?.absoluteString, "https://keyed.example/archiver.php?gid=3000&token=0000000bb8")
        let offer = KeyedWorkPage.archiveOffer(from: String(decoding: KeyedFixture.archivePage, as: UTF8.self))
        XCTAssertEqual(offer.funds, "1,200 GP · 393 Credits")
        XCTAssertEqual(offer.options, [.init(kind: "org", button: "Download Original Archive", cost: "446 GP", size: "21.24 MiB", available: true),
                                       .init(kind: "res", button: "Download Resample Archive", cost: "N/A", size: "N/A", available: false)],
                       "An archive the page greys out can't be chosen")
    }

    func testTagVotesGoToTheDetailsEndpointWithTheWorksKey() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        _ = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 3)
        signIn()
        let votes = try await source.voteTag(3000, tag: "female:sample tag", vote: -1)
        XCTAssertEqual(votes, [WorkTagVote(tag: "female:sample tag", vote: -1)], "The votes come back as they now stand")
        let request = try XCTUnwrap(fixture.voteRequests.last)
        XCTAssertEqual(request["tags"] as? String, "female:sample tag")
        XCTAssertEqual(request["token"] as? String, KeyedFixture.key(3000))
        XCTAssertEqual((request["apiuid"] as? NSNumber)?.intValue, 42)
        XCTAssertEqual((request["vote"] as? NSNumber)?.intValue, -1)
    }

    func testCommentsArePostedAndConfirmedOnTheWorkPage() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        _ = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 3)
        signIn()
        do {
            _ = try await source.postComment(3000, text: "short")
            XCTFail("The website takes no comment this short")
        } catch let error as SiteMessage { XCTAssertEqual(error.text, L10n.text("A comment is too short.")) }
        XCTAssertTrue(fixture.posted.isEmpty, "A short comment never reaches the website")

        let comments = try await source.postComment(3000, text: "A lovely work & thanks\nsecond line")
        XCTAssertTrue(comments.contains { $0.text.contains("A lovely work & thanks") }, "The comment shows on the work's page")
        XCTAssertEqual(fixture.posted.last, "A lovely work & thanks\nsecond line")

        fixture.commentRefusal = "You can only post one comment every minute."
        do {
            _ = try await source.postComment(3000, text: "Another comment that is long enough")
            XCTFail("A comment the website didn't take must not pass as posted")
        } catch let error as SiteMessage { XCTAssertEqual(error.text, "You can only post one comment every minute.") }
    }

    func testArchivesShowTheirCostAndDownloadFromTheAddressTheWebsiteHandsOut() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        _ = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 3)
        signIn()
        let offer = try await source.archiveOffer(3000)
        let original = try XCTUnwrap(offer.options.first { $0.isOriginal })
        XCTAssertTrue(fixture.archiveForms.isEmpty, "Looking at the offer costs nothing")
        let address = try await source.archiveDownloadURL(3000, option: original)
        XCTAssertEqual(address.absoluteString, "https://node1.volunteer.example:8440/archive/3000/abcdef/0?start=1")
        XCTAssertEqual(fixture.archiveForms, ["dltype=org&dlcheck=Download+Original+Archive"])
        do {
            _ = try await source.archiveDownloadURL(3000, option: try XCTUnwrap(offer.options.first { !$0.available }))
            XCTFail("An archive the page greys out is never requested")
        } catch { XCTAssertEqual(error as? ContentError, .invalidQuery) }
    }

    func testOriginalImagesLoadWhenChosenAndTheResizedPageShowsWhenRefused() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        let gallery = try await source.gallery(3000)
        fixture.offersOriginals = true
        signIn()
        _ = try await source.image(gallery.pages[1], galleryID: 3000, thumbnail: false)
        XCTAssertFalse(fixture.requests.contains { $0.path.hasPrefix("/fullimg/") }, "Originals load only when chosen")

        KeyedCatalogSource.setLoadsOriginals(true, host: "keyed.example")
        defer { KeyedCatalogSource.setLoadsOriginals(false, host: "keyed.example") }
        let original = try await source.image(gallery.pages[0], galleryID: 3000, thumbnail: false)
        XCTAssertEqual(original, Data(repeating: 0x77, count: 96))

        fixture.grantsOriginals = false
        let resized = try await MangaContentSource(transport: fixture.transport()).image(gallery.pages[2], galleryID: 3000, thumbnail: false)
        XCTAssertEqual(resized, fixture.image, "A page whose original the website keeps for GP shows resized")
    }

    func testTheChosenSettingsProfileIsSentWithEveryPage() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        _ = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 3)
        signIn()
        let profiles = try await source.settingsProfiles()
        XCTAssertEqual(profiles, [SiteSettingsProfile(id: 1, name: "Default Profile", selected: true), SiteSettingsProfile(id: 2, name: "Reading in the App", selected: false)])
        try await source.useSettingsProfile(2)
        let chosen = try await source.settingsProfiles()
        XCTAssertEqual(chosen.first { $0.selected }?.id, 2)
        XCTAssertTrue(fixture.cookies.last?.contains("sp=2") == true)
    }

    func testForgottenKeyIsFoundBySearchingTheNumber() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        _ = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 1)
        GalleryKeys.shared.removeAll()
        XCTAssertEqual(MangaUrls.galleryUrl(for: 2990), "https://keyed.example/?f_search=gid:2990")
        let gallery = try await source.gallery(2990)
        XCTAssertEqual(gallery.id, 2990)
        XCTAssertTrue(fixture.requests.contains { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "f_search", value: "gid:2990")) == true })
        XCTAssertEqual(GalleryKeys.shared.key(for: 2990), KeyedFixture.key(2990))
    }

    func testMembersOnlySiteAsksForSignInThenSendsOnlyTheIdentity() async throws {
        MangaUrls.preferences.set("members.example", forKey: "manga.site_address")
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        do {
            _ = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 2)
            XCTFail("A signed-out visitor sees nothing")
        } catch ContentError.signInRequired { }
        XCTAssertTrue(MangaUrls.requiresSignIn)
        XCTAssertEqual(MangaUrls.accountHost, "account.example")
        XCTAssertEqual(MangaUrls.signInURL?.absoluteString, "https://account.example/index.php?act=Login&CODE=00")

        let cookies = [("app_member_id", "42"), ("app_pass_hash", "secret"), ("tracking", "1")].map {
            HTTPCookie(properties: [.domain: ".account.example", .path: "/", .name: $0.0, .value: $0.1])!
        }
        XCTAssertTrue(SiteAccount.signIn(with: cookies, host: MangaUrls.configuredHost))
        MangaUrls.resetResolvedBackend()
        let batch = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 2)
        XCTAssertEqual(batch.ids, [3002, 3001])
        let header = try XCTUnwrap(fixture.cookies.last)
        XCTAssertTrue(header.contains("app_member_id=42") && header.contains("app_pass_hash=secret") && header.contains("nw=1"))
        XCTAssertFalse(header.contains("tracking"), "Only the account identity is kept from sign-in")
        XCTAssertTrue(header.contains("access=granted"), "Cookies the site grants are sent back to it")
        XCTAssertNil(SiteAccount.cookieHeader(for: URL(string: "https://covers.example/3000.jpg")!), "The identity never reaches other hosts")

        MangaUrls.preferences.set("catalog.example", forKey: "manga.site_address")
        XCTAssertNil(SiteAccount.cookieHeader(for: URL(string: "https://catalog.example/")!), "Sites that do not use accounts never receive it")
    }

    func testAccountFavoritesImportAndMirrorBookmarks() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        _ = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 1)
        do {
            _ = try await source.accountFavorites(after: nil)
            XCTFail("Favorites belong to a signed-in account")
        } catch ContentError.signInRequired { }
        let cookies = [("app_member_id", "42"), ("app_pass_hash", "secret")].map {
            HTTPCookie(properties: [.domain: ".keyed.example", .path: "/", .name: $0.0, .value: $0.1])!
        }
        XCTAssertTrue(SiteAccount.signIn(with: cookies, host: MangaUrls.configuredHost))
        let first = try await source.accountFavorites(after: nil)
        XCTAssertEqual(first.ids, [2998, 2990])
        XCTAssertEqual(first.next, "2990")
        let last = try await source.accountFavorites(after: first.next)
        XCTAssertEqual(last.ids, [2980])
        XCTAssertNil(last.next)
        XCTAssertNotNil(source.cachedPreview(2980), "Imported favorites carry their titles and tags")

        try await source.setAccountFavorite(3000, saved: true)
        try await source.setAccountFavorite(3000, saved: false)
        XCTAssertEqual(fixture.favoriteForms, ["favcat=0&favnote=&apply=Add+to+Favorites&update=1", "favcat=favdel&favnote=&apply=Apply+Changes&update=1"],
                       "Removing sends the submit button the form shows for it")
        XCTAssertTrue(fixture.requests.contains { $0.path == "/gallerypopups.php" && $0.query?.contains("t=\(KeyedFixture.key(3000))") == true })
    }

    func testPopularNarrowsBySearchLanguageAndCategory() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        let all = try await source.list(GalleryQuery(language: "all", sort: .today), offset: 0, count: 10)
        XCTAssertEqual(all.ids, [2999, 3000, 3001])
        let korean = try await source.list(GalleryQuery(language: "korean", sort: .today), offset: 0, count: 10)
        XCTAssertEqual(korean.ids, [3000, 3001])
        let manga = try await source.list(GalleryQuery(language: "all", text: "type:manga", sort: .today), offset: 0, count: 10)
        XCTAssertEqual(manga.ids, [3001])
        XCTAssertEqual(fixture.count(path: "/popular"), 1)
    }

    func testSuggestionsUseTheAppNamespacesAndCanonicalTags() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        let suggestions = try await source.suggestions(for: "-sample")
        XCTAssertEqual(suggestions.map(\.token), ["series:sample_series", "female:sample_tag"])
        let narrowed = try await source.suggestions(for: "series:sam")
        XCTAssertEqual(narrowed.map(\.token), ["series:sample_series"])
    }

    func testSiteLinksAndSearchesOpenInTheApp() {
        let link = "https://keyed.example/g/3000/\(KeyedFixture.key(3000))/"
        XCTAssertEqual(ContentRoute.initial(link), .gallery(3000))
        XCTAssertEqual(GalleryKeys.shared.key(for: 3000), KeyedFixture.key(3000))
        XCTAssertEqual(GalleryIDParser.parse("look at " + link), [3000])
        XCTAssertEqual(ContentRoute.initial("https://keyed.example/?f_search=gid%3A3000"), .gallery(3000))
        XCTAssertEqual(ContentRoute.initial("https://keyed.example/?f_search=artist%3A%22sample+artist%24%22+-other%3A%22x+y%24%22"),
                       .query("artist:sample_artist -tag:x_y"))
        XCTAssertNil(ContentRoute.initial("https://other.example/g/3000/\(KeyedFixture.key(3000))/"))
    }

    func testAccountsReadingInTheMultiPageViewerOpenWorksFromItsPageList() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        _ = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 3)
        fixture.viewer = true
        let gallery = try await source.gallery(3000)
        XCTAssertEqual(gallery.pages.map(\.name), ["one.jpg", "two & three.jpg", "3"])
        XCTAssertEqual(gallery.pages[1].thumbnailURL?.absoluteString, "https://sheets.example/large-2.jpg")
        XCTAssertEqual(fixture.count(path: "/mpv/3000/\(KeyedFixture.key(3000))"), 1)
        let page = try await source.image(gallery.pages[1], galleryID: 3000, thumbnail: false)
        XCTAssertEqual(page, fixture.image)
        XCTAssertTrue(fixture.requests.contains { $0.path == "/s/bbbbbbbbbb/3000-2" }, "Each page opens with the key the viewer lists for it")
        let preview = try await source.image(gallery.pages[1], galleryID: 3000, thumbnail: true)
        XCTAssertEqual(preview, fixture.image)
    }

    func testLargePreviewsAreWholeImages() {
        let page = #"<div id="gdt" class="gt200"><a href="https://keyed.example/s/1111111111/3000-1"><div title="Page 1: one.jpg" style="width:200px;height:283px;background:transparent url(https://sheets.example/large-1.webp) 0 0 no-repeat"></div></a></div>"#
        let entry = KeyedCatalogSource.entries(in: page, galleryID: 3000)[0]
        XCTAssertEqual(entry?.thumb, KeyedCatalogSource.Thumb(url: URL(string: "https://sheets.example/large-1.webp")!, crop: nil))
        XCTAssertEqual(entry?.name, "one.jpg")
        let relative = #"<a href="https://keyed.example/s/1111111111/3000-1"><div title="Page 1: one.jpg" style="width:100px;height:150px;background:transparent url(/t/sheet.jpg) -100px 0 no-repeat"></div></a>"#
        XCTAssertEqual(KeyedCatalogSource.entries(in: relative, galleryID: 3000)[0]?.thumb,
                       KeyedCatalogSource.Thumb(url: URL(string: "https://keyed.example/t/sheet.jpg")!, crop: CGRect(x: 100, y: 0, width: 100, height: 150)),
                       "A preview starting at the root belongs to the page link beside it")
    }

    func testPreviewTilesAreCutFromTheSheet() throws {
        let tile = try KeyedCatalogSource.cropped(KeyedFixture.sheet, to: CGRect(x: 100, y: 0, width: 100, height: 150))
        let image = try XCTUnwrap(UIImage(data: tile)?.cgImage)
        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 150)
        let entries = KeyedCatalogSource.entries(in: String(decoding: KeyedFixture.detail(3000, page: 0), as: UTF8.self), galleryID: 3000)
        XCTAssertEqual(entries[1]?.thumb?.crop, CGRect(x: 100, y: 0, width: 100, height: 150))
        XCTAssertEqual(entries[1]?.key, "2222222222")
        XCTAssertTrue(entries[0]?.thumb.flatMap(KeyedCatalogSource.encoded).map { KeyedCatalogSource.thumb(from: $0) == entries[0]?.thumb } ?? false)
    }
}

private final class KeyedFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    private var sentCookies: [String] = []
    private var forms: [String] = []
    var failFirstNode = false
    var allowanceUsed = false
    /// Words the first image host sends instead of the image.
    var textAnswer: String?
    /// How many details requests fail before they answer.
    var failDetails = 0
    /// Image pages link a larger original, which the website sends or refuses.
    var offersOriginals = false
    var grantsOriginals = true
    /// Comments posted under work 3000, and the website's answer when it won't take one.
    var posted: [String] = []
    var commentRefusal: String?
    var voteRequests: [[String: Any]] { lock.withLock { votes } }
    private var votes: [[String: Any]] = []
    var archiveForms: [String] { lock.withLock { archives } }
    private var archives: [String] = []
    /// The note the favorites form shows, as the page writes it.
    var favoriteNote = ""
    var favoriteReply = "<html><script>window.opener.location.reload();</script></html>"
    /// The account reads in the multi-page viewer, so work pages link there instead of to each page.
    var viewer = false
    let image = Data(repeating: 0x42, count: 64)
    var requests: [URL] { lock.withLock { recorded } }
    var cookies: [String] { lock.withLock { sentCookies } }
    var favoriteForms: [String] { lock.withLock { forms } }
    func count(path: String) -> Int { requests.filter { $0.path == path }.count }

    static func key(_ id: Int64) -> String {
        let hex = String(id, radix: 16)
        return String(repeating: "0", count: 10 - hex.count) + hex
    }

    static let sheet: Data = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 150), format: {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
    }()).pngData { context in
        UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 150))
        UIColor.blue.setFill(); context.fill(CGRect(x: 100, y: 0, width: 100, height: 150))
    }

    func transport() -> ContentTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KeyedFixtureProtocol.self]
        return ContentTransport(configuration: configuration)
    }

    private static func listing(_ ids: [Int64], next: Int64?) -> Data {
        let rows = ids.map { #"<tr><td class="gl3c"><a href="https://keyed.example/g/\#($0)/\#(key($0))/"><div class="glink">Sample \#($0)</div></a></td></tr>"# }.joined()
        let nav = next.map { #"<div class="searchnav"><a id="unext" href="https://keyed.example/?f_search=x&amp;next=\#($0)">Next &gt;</a></div>"# } ?? #"<div class="searchnav"><span id="unext">Next &gt;</span></div>"#
        return Data(#"<html><body><form><input type="text" id="f_search" name="f_search"></form><table class="itg">\#(rows)</table>\#(nav)</body></html>"#.utf8)
    }

    static func detail(_ id: Int64, page: Int, comments: [String] = []) -> Data {
        let entries: [(String, Int, String, String, Int)] = page == 0
            ? [("1111111111", 1, "one.jpg", "\(id)-0.png", 0), ("2222222222", 2, "two.jpg", "\(id)-0.png", -100)]
            : [("3333333333", 3, "three.jpg", "\(id)-1.png", 0)]
        let links = entries.map { key, number, name, sheet, offset in
            #"<a href="https://keyed.example/s/\#(key)/\#(id)-\#(number)"><div title="Page \#(number): \#(name)" style="width:100px;height:150px;background:transparent url(https://sheets.example/\#(sheet)) \#(offset)px 0 no-repeat"></div></a>"#
        }.joined()
        let thread = comments.enumerated().map { index, text in
            #"<div class="c1"><div class="c2"><div class="c3">Posted on 01 January 2026, 00:00 by: &nbsp; <a href="https://keyed.example/uploader/me">me</a></div></div><div class="c6" id="comment_\#(index + 1)">\#(text)</div></div>"#
        }.joined()
        let extras = ##"<div id="taglist"><table><tr><td class="tc">female:</td><td><div id="td_female:sample_tag" class="gt"><a id="ta_female:sample_tag" href="https://keyed.example/tag/female:sample+tag" class="tup" onclick="return toggle_tagmenu(1,'female:sample tag',this)">sample tag</a></div></td></tr><tr><td class="tc">parody:</td><td><div id="td_parody:sample_series" class="gtl"><a id="ta_parody:sample_series" href="https://keyed.example/tag/parody:sample+series" class="" onclick="return toggle_tagmenu(2,'parody:sample series',this)">sample series</a></div></td></tr></table></div><p class="g2"><a href="#" onclick="return popUp('https://keyed.example/archiver.php?gid=\##(id)&amp;token=\##(key(id))',480,320)">Archive Download</a></p><div id="cdiv">\##(thread)</div><div id="formdiv" style="display:none"><form method="post" action="#cnew"><textarea name="commenttext_new"></textarea></form></div>"##
        return Data(#"<html><script>var api_url = "https://api.keyed.example/api.php";\#nvar login_url = "https://keyed.example/bounce_login.php?b=d&bt=1";\#nvar apiuid = 42;\#nvar apikey = "0123abcd4567";</script><div id="gdt">\#(links)</div>\#(page == 0 ? extras : "")</html>"#.utf8)
    }

    static let archivePage = Data(#"""
    <html><body><div id="db"><h1>Sample 3000</h1><p>Current Funds:</p><p>1,200 GP [<a href="#">?</a>] &nbsp; 393 Credits [<a href="#">?</a>]</p>
    <div><div style="width:180px; float:left"><div style="text-align:center">Download Cost: &nbsp; <strong>446 GP</strong></div>
    <form action="https://keyed.example/archiver.php?gid=3000&amp;token=0000000bb8" method="post"><input type="hidden" name="dltype" value="org"><div><input type="submit" name="dlcheck" value="Download Original Archive"></div></form>
    <p>Estimated Size: &nbsp; <strong>21.24 MiB</strong></p></div>
    <div style="width:180px; float:right; color:#CCCCCC"><div style="text-align:center">Download Cost: &nbsp; <strong>N/A</strong></div>
    <form action="https://keyed.example/archiver.php?gid=3000&amp;token=0000000bb8" method="post"><input type="hidden" name="dltype" value="res"><div><input type="submit" name="dlcheck" value="Download Resample Archive"></div></form>
    <p>Estimated Size: &nbsp; <strong>N/A</strong></p></div></div></div></body></html>
    """#.utf8)

    static func viewerDetail(_ id: Int64) -> Data {
        let links = (1...3).map { number in
            #"<a href="https://keyed.example/mpv/\#(id)/\#(key(id))/#page\#(number)"><div title="Page \#(number): x" style="width:100px;height:150px;background:transparent url(https://sheets.example/\#(id)-0.png) -\#((number - 1) * 100)px 0 no-repeat"></div></a>"#
        }.joined()
        return Data(#"<html><div id="gdt">\#(links)</div><p>a work page with enough text to be a real page</p></html>"#.utf8)
    }

    static let viewerPage = Data(#"""
    <html><body><div id="pane_images"></div><script type="text/javascript">
    var gid=3000;
    var mpvkey = "0123456789a";
    var imagelist = [{"n":"one.jpg","k":"aaaaaaaaaa","t":"https:\/\/sheets.example\/large-1.jpg"},{"n":"two &amp; three.jpg","k":"bbbbbbbbbb","t":"https:\/\/sheets.example\/large-2.jpg"},{"n":"","k":"cccccccccc","t":"https:\/\/sheets.example\/large-3.jpg"}];
    </script></body></html>
    """#.utf8)

    private func details(_ body: Data) throws -> Data {
        let request = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        if request["method"] as? String == "taggallery" {
            lock.withLock { votes.append(request) }
            let vote = (request["vote"] as? NSNumber)?.intValue ?? 0
            let pane = #"<div id="taglist"><a id="ta_female:sample_tag" class="\#(vote > 0 ? "tup" : "tdn")" onclick="return toggle_tagmenu(1,'female:sample tag',this)">sample tag</a></div>"#
            return try JSONSerialization.data(withJSONObject: ["tagpane": pane])
        }
        if request["method"] as? String == "tagsuggest" {
            return try JSONSerialization.data(withJSONObject: ["tags": ["1": ["ns": "parody", "tn": "sample series"],
                                                                         "2": ["ns": "temp", "tn": "sample alias", "mns": "female", "mtn": "sample tag"],
                                                                         "3": ["ns": "temp", "tn": "loose word"]]])
        }
        let items = (request["gidlist"] as! [[Any]]).map { pair -> [String: Any] in
            let id = (pair[0] as! NSNumber).int64Value
            guard pair[1] as? String == Self.key(id) else { return ["gid": id, "error": "Key missing, or incorrect key provided."] }
            var tags = [id == 2999 ? "language:japanese" : "language:korean", "artist:sample artist", "parody:sample series", "other:sample tag"]
            if id != 2999 { tags.append("language:translated") }
            if id == 3002 { tags.append("female:marked tag") }
            return ["gid": id, "token": Self.key(id), "title": "Sample \(id)", "title_jpn": "原題 \(id)",
                    "category": id == 3001 ? "Manga" : "Doujinshi", "thumb": "https://covers.example/\(id).jpg",
                    "filecount": "3", "uploader": "uploader &amp; \(id)", "tags": tags]
        }
        return try JSONSerialization.data(withJSONObject: ["gmetadata": items])
    }

    enum Reply {
        case data(Int, Data, [String: String])
        case redirect(URL)
    }

    func reply(_ request: URLRequest) throws -> Reply {
        let url = request.url!
        lock.withLock {
            recorded.append(url)
            if let cookie = request.value(forHTTPHeaderField: "Cookie") { sentCookies.append(cookie) }
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host {
        case "covers.example": return .data(200, image, ["Content-Type": "image/jpeg"])
        case "sheets.example":
            return url.path.hasPrefix("/large-") ? .data(200, image, ["Content-Type": "image/jpeg"]) : .data(200, Self.sheet, ["Content-Type": "image/png"])
        case "node1.volunteer.example":
            if let textAnswer { return .data(200, Data(textAnswer.utf8), ["Content-Type": "text/html; charset=UTF-8"]) }
            return failFirstNode ? .data(503, Data(), [:]) : .data(200, image, ["Content-Type": "image/webp"])
        case "node2.volunteer.example": return .data(200, image, ["Content-Type": "image/webp"])
        case "notice.example": return .data(200, image, ["Content-Type": "image/gif"])
        case "api.keyed.example", "api.members.example":
            let fails = lock.withLock { () -> Bool in
                guard failDetails > 0 else { return false }
                failDetails -= 1
                return true
            }
            if fails { return .data(503, Data(), [:]) }
            return .data(200, try details(Self.body(request)), ["Content-Type": "application/json"])
        case "members.example":
            guard (request.value(forHTTPHeaderField: "Cookie") ?? "").contains("app_member_id=42") else {
                return .redirect(URL(string: "https://account.example/remoteapi.php?ex=token")!)
            }
            if url.path == "/" {
                return .data(200, Self.listing([3002, 3001, 3000], next: nil), ["Content-Type": "text/html", "Set-Cookie": "access=granted; path=/"])
            }
            return .data(200, Self.detail(3002, page: 0), ["Content-Type": "text/html"])
        case "keyed.example": break
        default: return .data(404, Data(), [:])
        }
        switch url.path {
        case "/":
            if let search = items.first(where: { $0.name == "f_search" })?.value, search.hasPrefix("gid:"), let id = Int64(search.dropFirst(4)) {
                return .data(200, Self.listing([id], next: nil), ["Content-Type": "text/html"])
            }
            let next = items.first { $0.name == "next" }?.value
            let ids: [Int64] = next == nil ? [3002, 3001, 3000] : [2999, 2998]
            var shown = ids
            if let cats = items.first(where: { $0.name == "f_cats" })?.value, let mask = Int(cats), mask != 0, mask & 4 == 0 { shown = ids.filter { $0 == 3001 } }
            return .data(200, Self.listing(shown, next: next == nil ? 2999 : nil), ["Content-Type": "text/html"])
        case "/popular": return .data(200, Self.listing([2999, 3000, 3001], next: nil), ["Content-Type": "text/html"])
        case "/uconfig.php":
            let chosen = (request.value(forHTTPHeaderField: "Cookie") ?? "").contains("sp=2") ? 2 : 1
            let options = [(1, "Default Profile"), (2, "Reading in the App")].map { #"<option value="\#($0.0)"\#($0.0 == chosen ? #" selected="selected""# : "")>\#($0.1)</option>"# }.joined()
            return .data(200, Data(#"<html><body><div id="profile_outer"><select name="profile_set" onchange="do_profile_post()">\#(options)</select></div><p>settings page with enough text to read</p></body></html>"#.utf8), ["Content-Type": "text/html"])
        case "/archiver.php":
            guard request.httpMethod == "POST" else { return .data(200, Self.archivePage, ["Content-Type": "text/html"]) }
            lock.withLock { archives.append(String(decoding: Self.body(request), as: UTF8.self)) }
            return .data(200, Data(#"<html><body><script type="text/javascript">document.location = "https://node1.volunteer.example:8440/archive/3000/abcdef/0";</script><p>Your archive is ready, the download starts in a moment.</p></body></html>"#.utf8), ["Content-Type": "text/html"])
        case "/favorites.php":
            guard (request.value(forHTTPHeaderField: "Cookie") ?? "").contains("app_member_id=42") else {
                return .data(200, Data(#"<html><form><input type="password" name="PassWord"></form></html>"#.utf8), ["Content-Type": "text/html"])
            }
            let next = items.first { $0.name == "next" }?.value
            return .data(200, next == nil ? Self.listing([2998, 2990], next: 2990) : Self.listing([2980], next: nil), ["Content-Type": "text/html"])
        case "/gallerypopups.php":
            guard request.httpMethod == "POST" else {
                let popup = #"<html><body><div id="galpop"><form method="post"><textarea name="favnote" maxlength="200">\#(favoriteNote)</textarea></form></div></body></html>"#
                return .data(200, Data(popup.utf8), ["Content-Type": "text/html"])
            }
            lock.withLock { forms.append(String(decoding: Self.body(request), as: UTF8.self)) }
            return .data(200, Data(favoriteReply.utf8), ["Content-Type": "text/html"])
        default:
            let parts = url.path.split(separator: "/")
            if parts.first == "g", parts.count == 3, let id = Int64(parts[1]), String(parts[2]) == Self.key(id) {
                if request.httpMethod == "POST" {
                    let form = String(decoding: Self.body(request), as: UTF8.self)
                    let text = (form.hasPrefix("commenttext_new=") ? String(form.dropFirst(16)) : "").replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
                    if let commentRefusal {
                        let page = String(decoding: Self.detail(id, page: 0, comments: posted), as: UTF8.self).replacingOccurrences(of: "<html>", with: #"<html><p class="br">\#(commentRefusal)</p>"#)
                        return .data(200, Data(page.utf8), ["Content-Type": "text/html"])
                    }
                    lock.withLock { posted.append(text) }
                }
                let comments = lock.withLock { posted }
                return .data(200, viewer ? Self.viewerDetail(id) : Self.detail(id, page: url.query == "p=1" ? 1 : 0, comments: comments), ["Content-Type": "text/html"])
            }
            if parts.first == "fullimg" {
                return grantsOriginals ? .data(200, Data(repeating: 0x77, count: 96), ["Content-Type": "image/png"])
                    : .data(200, Data("Downloading original files of this gallery during peak hours requires GP, and you do not have enough.".utf8), ["Content-Type": "text/html"])
            }
            if parts.first == "mpv", parts.count == 3, let id = Int64(parts[1]), String(parts[2]) == Self.key(id) {
                return .data(200, Self.viewerPage, ["Content-Type": "text/html"])
            }
            if parts.first == "s", parts.count == 3, let number = parts[2].split(separator: "-").last {
                let reload = items.first { $0.name == "nl" }?.value
                let host = allowanceUsed ? "https://notice.example/g/509.gif" : reload == nil ? "https://node1.volunteer.example:8440/h/\(number).webp" : "https://node2.volunteer.example:8440/h/\(number).webp"
                let original = offersOriginals ? #"<div id="i6"><a href="https://keyed.example/fullimg/3000/\#(number)/okey123/orig.png">Download original 2400 x 3400 3.1 MiB source</a></div>"# : ""
                let page = #"<html><div id="i3"><a href="/next"><img id="img" src="\#(host)" onerror="this.onerror=null; nl('alt-\#(number)')"></a></div>\#(original)<p>reader page with enough text to be a real page</p></html>"#
                return .data(200, Data(page.utf8), ["Content-Type": "text/html"])
            }
            return .data(404, Data(), [:])
        }
    }

    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private final class KeyedFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var fixture: KeyedFixture?
    static func install(_ fixture: KeyedFixture?) { lock.withLock { Self.fixture = fixture } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let fixture = Self.lock.withLock({ Self.fixture }) else { throw URLError(.cancelled) }
            switch try fixture.reply(request) {
            case .data(let status, let data, let headers):
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case .redirect(let target):
                let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
