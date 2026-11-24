# GSD Cloud — קבלה פונקציונלית, 24.11.2026

## מסקנה והיקף

**דרישות הפיתוח של [משימת Cloud ‏1220825972434803][cloud-task], עבור הרכיבים והמקורות שנבדקו כאן, מתקיימות באמצעות ראיות משלימות של האפליקציה הנייטיבית, מנוע הסנכרון והשרת החי.** אין צורך בהרצת Cloud נוספת שמכפילה אותן. התקנה ושימוש אישי באייפד חדש נשארים ב[משימת המסירה למכשיר פיזי ‏1220773422959000][physical-task].

זהו סיכום קבלה ממוקד, הנלווה ל[דוח האינטגרציה הקיים][integration]. הוא אינו משנה סטטוס ב־Asana ואינו קובע שההרשאות האישיות של ChatGPT או כל הפרויקט הושלמו. לא הורצו בדיקות, נוצרו חשבונות או שונו שירותים לצורך כתיבתו.

המקור שנבדק בפועל הוא [`71b1b7ce4adf7bea2ddacfc683a69906d6acd6ae`][app-source], בריצת [45397928701][native-run]. מקור ה־workflow הוא `d0c5b9649a95e34aef0d4a641a28e2b7382bec0f`; אלה מזהים שונים. הקומפילציה השתמשה ב־Xcode 27.1 / 27A9275, ונהג XCTest ב־Xcode 27.0 / 27A266a, מול iOS 27.2 / 24B8117. מקור התיעוד למסמך זה הוא `c04b07c58d810a5295f76cb2ea43f708b62bb9a9`; אין שינוי למקור האפליקציה.

המסלול הרגיל משתמש ב־GSDWire, GSDSync, SyncEngine, TaskStore ו־GRDB הקיימים וב[כתובת הענן המשותפת][endpoint] `https://torah-social.tail0a6c7d.ts.net:10000/gsd-cloud`. הוכחת החשבון הנייטיבי להלן נעשתה בהפעלה רגילה מול Oracle.

## מיפוי דרישות להוכחה

| דרישה | מה הוכח בפועל | מקור ותוצאה מדויקים |
|---|---|---|
| יצירת חשבון, התחברות, יציאה ושמירת Session | טופס ההרשמה הנייטיבי יצר חשבון; UI ביצע יציאה והתחברות לאותו חשבון; הפעלה חוזרת שמרה את הנתונים. בדיקות AuthService מכסות חידוש מוקדם, דחיית חידוש, כשל זמני ואי־מחיקת Session תקף בזמן אופליין. | [בדיקת UI `test02CloudChangesArriveAfterClosedAppAndLocalChangesUpload`][native-test] עברה ב־**110.990 שניות**; [קבלת הריצה][native-receipt]. `CloudAccountAuthTests` ו־[`AuthServiceTests`][auth-tests] עברו במסגרת **94 בדיקות / 7 suites**. בדיקת קוד SessionStore בפועל עברה **13/0**, עם תחליפי תלות פלטפורמה המתועדים ב[דוח התצפית][session-report]. |
| סנכרון דו־כיווני כשהאפליקציה סגורה | ה־UI אימת `app.notRunning`, יצר משימה בשרת, פתח את האפליקציה וראה אותה. משימה שנוצרה ב־UI הופיעה בשרת; שתי המשימות נשמרו בהפעלה חוזרת. | אותה בדיקת UI של **110.990 שניות**; [צילומים וגאומטריה מקוריים][native-images]. בנוסף, תרחיש GRDB החי משך משימה שנוצרה לפני הפעלת המנוע. |
| שינוי מקומי באופליין וסנכרון בחזרת חיבור | TaskStore אמיתי הכניס שינוי לתור מקומי; SyncEngine אמיתי שלח אותו ל־Oracle והשרת החזיר אותו. בנפרד, קוד SyncCoordinator בפועל תזמן בדיוק סנכרון התאוששות אחד באירוע loss→return, דחה אירועים חוזרים וכיבד עצירה ברקע, יציאה, החלטת חשבון ומחיקת חשבון. | [`closedNativePullOfflinePushNewDeviceAndAccountIsolation`][live-test] עבר מול השרת ב־**5.739 שניות**. [בדיקת תזמון הקישוריות][connectivity-report] עברה **8/0** עם monitor מבוקר וגבול מנוע רושם. בתרחיש החי קריאת `.networkRegained` מפורשת; **רדיו/רשת של מערכת ההפעלה לא הוחלפו בפועל**. שתי הראיות מכסות רכיבים משלימים. |
| התנגשויות, גרסאות ומרוצים | בשרת חי נבדקו עדכון מותנה, דחיית גרסה ישנה ב־412, דחיית שינוי ללא גרסה חדשה והגנה על owner. במנוע וב־GRDB האמיתיים נבדקו מרוצי עדכון/מחיקה, אובדן תגובה, עריכה מקומית חדשה וסדר הפעולות. | [Public E2E][public-log], checkpoints ‏`native_wire_guarded_update_stale_conflict_and_owner_immutability` ו־`native_archive_view_tombstones_version_conflicts_and_account_isolation`. [`SyncEngineGuardedWriteTests`][guarded-tests] ו־[`CloudLibraryOrderingTests`][ordering-tests] עברו בתוך 94 הבדיקות, עם HTTP מבוקר. תרחיש 5.739 השניות **אינו** מייצר בעצמו התנגשות גרסאות. |
| מחיקות, tombstones ומניעת כפילויות | סנכרון חוזר נשאר בדיוק עם שתי משימות. מחיקת TaskStore נשלחה לשרת; המנוע השני הסיר את השורה הפעילה והחזיר אותה ל־Trash במסד שלו. נבדקו tombstone של view, הפרדת metadata של מחיקה לפי חשבון ו־idempotency של השלמת משימה חוזרת. | [התרחיש החי][live-test], [Public E2E][public-log] ו־[`CloudLibrarySyncTests`][library-tests] — **4/4**. בין הבדיקות: `localDeletionProducesDurableOwnerScopedTombstone`, `remoteTrashCannotDestroyANewerPendingLocalEdit`, `freshAccountResetCannotUploadOldDeletionMetadata`. בדיקות ה־GRDB האלה משתמשות במסדים בזיכרון; אין לייחס להן פתיחה מחדש של קובץ DB. |
| מכשיר חדש עם אותו חשבון | נוצרו **שני AppDatabase.inMemory נפרדים ושני SyncEngine אמיתיים**, עם cursor ומזהה מכשיר נפרדים. המסד השני, שהיה ריק, קיבל את אותן שתי משימות של חשבון A ובהמשך את המחיקה/Trash; הוא לא הועתק מהמסד הראשון. | [התרחיש החי, 5.739 שניות][live-test]. זו הוכחת בנייה מחדש של מצב מקומי נקי מול Oracle. התקנת האפליקציה באייפד אישי נוסף נשארת ב[מסירה הפיזית][physical-task]; אין פער נוסף המחייב חזרה על תרחיש המסד הנקי. |
| בידוד שני חשבונות ושינוי חשבון באמצע סנכרון | חשבונות A/B אמיתיים נבדקו מול Oracle: B לא ראה tasks או library של A; גם MCP לא חשף משימה של החשבון האחר. קוד המנוע והמסד נבדקו מול החלפת חשבון/יציאה במהלך pull, push ו־reconciliation, בלי כתיבה מאוחרת של החשבון הקודם. | [התרחיש החי][live-test] ו־[Public E2E][public-log]; [`SyncEngineSessionFenceTests`][fence-tests] ו־[`AccountSwitchTests`][switch-tests] עברו בתוך 94 הבדיקות עם גבולות HTTP/Session מבוקרים. |
| מחיקת החשבון והנתונים | מחיקה נייטיבית הותירה UI מנותק ומשימות מקומיות חסרות; קריאת המשתמש, refresh והתחברות חוזרת נדחו בחוזים מובְנים. שאילתת Oracle נפרדת, לקריאה בלבד ועל אותו owner בדיוק, מצאה **users 0 / tasks 0 / gsd_library 0**. | בדיקת ה־UI החיה; [קבלת Oracle של Root מ־13:37:06 UTC][owner-zero]. בנוסף, `AccountDeleterTests` ו־`AccountDeletionRecoveryTests` עברו **18 בדיקות / 2 suites**. מחיקת API לגיבוי לא זוכתה כמחיקה נייטיבית. |

## תוצאות שמורות ומקורן

ב[ארטיפקט הריצה 14923656158][native-artifact] נשמרו התוצאות הבאות; הן נקראו ואומתו, ולא הורצו שוב לצורך מסמך זה:

| קובץ תוצאה | תוצאה | SHA-256 |
|---|---|---|
| `logs/cloud-sync-tests.log` | 94/7, התרחיש החי 5.739s; timer 3; library 4 | `732469c7b042d157319b3e953ccd3146a9937f28786f8d32299b1fbff259e469` |
| `logs/sync-connectivity.log` | `SYNC_CONNECTIVITY_RESULT passed=8 failed=0` | `2840901512635ffa0dc655b780d0191ea13f34fb23d04453573371df6dd3c550` |
| `logs/session-observation.log` | `SESSION_OBSERVATION_RESULT passed=13 failed=0` | `7236971cbd6a2f2643a9fc1e5386ecda59ebdc22ab09e49621099fa7c089d090` |
| `logs/account-deletion-tests.log` | 18/2 passed | `16dd000109f66d51e5910c7aabc6619b0f0e745dfd0731eb526d5fb4b06bb823` |

הארטיפקט המלא: 90,068,222 bytes, SHA-256 `7a9982bc82a7f15fffcac133bdddebb238c35893cf219c8e6c2eebfec15e08a4`. [קבלת ה־UI][native-receipt] מאמתת **13 מקרים ייחודיים שעברו**, בלי כישלון או דילוג, בארבעה שילובי iPhone/iPad ועברית/אנגלית. סיכומי היחידות והחוזים אינם מוצגים כאילו כל אחד מהם הוא בדיקת UI או שרת חי.

[Public E2E][public-log] עבר **9 checkpoints**, כולל ביצוע ממשי של **כל 22 כלי MCP**, על מקור ענן `0e8911a33fc29eed8dfd969e43a0e6a86b63c9a4`. [קבלת התעבורה][public-receipt] מאשרת TLS ציבורי, exit 0 וניקוי החשבונות הסינתטיים. נבדקו OAuth PKCE, קוד חד־פעמי, scope לקריאה בלבד, חידוש/החלפת refresh token, דחיית replay וביטול grant. [בדיקת דפי OAuth][oauth-report] מוסיפה תצפית דפדפן HE→EN→HE. **אלה אינן הרשאת Connect אישית בתוך ChatGPT, ואינן הרשאת Continue with ChatGPT או הוכחת זכאות למכסת מנוי.**

## גיבוי ושחזור

[קבלת הגיבוי המתוזמן][calendar-report] מאשרת הפעלת timer של Oracle ב־**03:18:35 UTC**, סיום service בהצלחה, בדיקת integrity ו־restore, וכן הרצת Windows מוצלחת ב־**03:35** עם CurrentUser DPAPI ובדיקת hash/manifest. תמונת הייצור שנבדקה הכילה **1 משתמש / 0 משימות / 0 רשומות library**. הפעלת Windows תאמה את שעת ה־CalendarTrigger, אך היסטוריית Scheduler לא הוכיחה אם הגורם היה calendar או logon. ההרצה האוטומטית תלויה ב־Windows זמין ומחובר ובפרופיל המשתמש הקיים; שחזור DPAPI אינו מוכח בפרופיל חלופי. מדיניות השמירה של הגיבוי החיצוני היא שבעה ארכיונים ייעודיים.

[בדיקת השחזור הלא־ריק][recovery-report], שפורסמה ב־`540bde78d1eb7b90de9eb12d20d319d1c439f1f4`, עברה ב־**07:08:46 UTC**: PocketBase ‏0.40.6 אמיתי, מימוש `backup.py` ללא שינוי, **1 משתמש / 1 משימה / 1 רשומת library**, עצירת המקור, מופע משוחזר נפרד, התחברות חדשה ושוויון מלא של הרשומות וה־digests. תהליכי וקובצי הבדיקה נוקו; שירותי הייצור נשארו ללא שינוי. זו הוכחת שחזור תוכן באותו שרת בסביבה מבודדת, ולא מעבר ייצור מלא, שחזור volume או שחזור מענקי OAuth.

## תצפיות תפעוליות היסטוריות — ללא בדיקה חדשה

[הקבלה המצורפת][health-receipt] משמרת את שתי תוצאות ה־jobs המקוריות, כולל הטקסט המקורי ו־SHA-256 שלו. לא נשלחה קריאת Oracle חדשה לצורך פרסום זה. שתי התצפיות קודמות לפריסת OAuth/MCP מאוחרת שעליה דיווח Root בתיאום העבודה; הן אינן מאמתות PID או בריאות לאחר פריסה זו.

- **15:26:40 UTC**, `job_bfcee0a73f0c`: שש זהויות השירות המקוריות והמאזינים נשארו ללא שינוי. נפח זמין: **8,448,753,664 bytes בנתונים** ו־**1,301,319,680 bytes ב־root**. PocketBase החזיר HTTP 200 ו־body code 200; Gateway החזיר HTTP 200. התוצאה המקורית `passed:false` נשמרת: המשווה ציפה בטעות ל־`code` מספרי גם ב־Gateway, שבו שדה זה חסר.
- **15:28:19 UTC**, `job_7b7ac116b8d2`: קריאת הבהרה ל־`/gsd-cloud/health` החזירה **HTTP 200, `ok:true`, `version:"1.0.0"`**. זו סכמת ה־Gateway הנכונה; ה־false הראשון אינו ראיה להשבתה. שתי התצפיות המוגבלות אינן הבטחת זמינות רציפה.
- השינוי בנפח הזמין מאז התצפיות הקודמות **אינו מיוחס לגורם שלא נבדק**. הבדיקות האלה לא מחקו קבצים ולא שינו volume, שירותים או נתונים. זהות ושקעים של Lorvex הם ראיית רציפות שירות, לא בדיקת שימוש פונקציונלית של Lorvex.

## גבול הסגירה

מבחינת הרכיבים שנבדקו, הראיות לעיל מספיקות לקבלת **פיתוח Cloud**. לפני סגירת המצב הנוכחי, Root משלים התאמה מול פריסת OAuth/MCP מקבילה שדווחה ב־15:34 על מקור מקומי `98d298bb4ea3ebc2266e80b7e883c00573365a71`, לפי [דיווח הפריסה ב־Asana, תגובה `1220868967995684`][later-auth-report]. המסמך אינו מוסיף אימות עצמאי של פריסה זו ואינו מחיל עליה אוטומטית את תוצאות הבדיקות הקודמות. אין דרישה להפוך כל בדיקת מנוע, חוזה או מסד לבדיקה חוזרת דרך UI כאשר הרכיב עצמו כבר נבדק. התצפיות האישיות שנותרו — התקנת TestFlight, שימוש בחשבון באייפד פיזי חדש והרשאות ChatGPT — נשארות במשימות המסירה וההרשאה המתאימות. לא נטען שבוצעה החלפת רדיו OS, התקנה באייפד אישי שני, הרשאת ChatGPT אישית או שחזור אסון מלא.

[cloud-task]: https://app.asana.com/0/1220770501963372/1220825972434803
[physical-task]: https://app.asana.com/0/1220770501963372/1220773422959000
[integration]: GSD_INTEGRATION_20261124.md
[app-source]: https://github.com/davidpovarsky/gsd-iosapp/commit/71b1b7ce4adf7bea2ddacfc683a69906d6acd6ae
[native-run]: https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45397928701
[native-artifact]: https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45397928701/artifacts/14923656158
[native-receipt]: evidence/native-45397928701/native-acceptance.json
[native-images]: evidence/native-45397928701/manifest.json
[owner-zero]: evidence/native-45397928701/oracle-owner-zero.json
[endpoint]: https://github.com/davidpovarsky/gsd-iosapp/blob/71b1b7ce4adf7bea2ddacfc683a69906d6acd6ae/GSDKit/Sources/GSDWire/PocketBaseEndpoint.swift
[native-test]: https://github.com/davidpovarsky/gsd-iosapp/blob/71b1b7ce4adf7bea2ddacfc683a69906d6acd6ae/ScreenshotTests/GSDCloudReleaseUITests.swift
[live-test]: https://github.com/davidpovarsky/gsd-iosapp/blob/71b1b7ce4adf7bea2ddacfc683a69906d6acd6ae/GSDKit/Tests/GSDSyncTests/CloudNativeSystemTests.swift
[auth-tests]: https://github.com/davidpovarsky/gsd-iosapp/blob/71b1b7ce4adf7bea2ddacfc683a69906d6acd6ae/GSDKit/Tests/GSDSyncTests/AuthServiceTests.swift
[guarded-tests]: https://github.com/davidpovarsky/gsd-iosapp/blob/71b1b7ce4adf7bea2ddacfc683a69906d6acd6ae/GSDKit/Tests/GSDSyncTests/SyncEngineGuardedWriteTests.swift
[ordering-tests]: https://github.com/davidpovarsky/gsd-iosapp/blob/71b1b7ce4adf7bea2ddacfc683a69906d6acd6ae/GSDKit/Tests/GSDSyncTests/CloudLibraryOrderingTests.swift
[library-tests]: https://github.com/davidpovarsky/gsd-iosapp/blob/71b1b7ce4adf7bea2ddacfc683a69906d6acd6ae/GSDKit/Tests/GSDStoreTests/CloudLibrarySyncTests.swift
[fence-tests]: https://github.com/davidpovarsky/gsd-iosapp/blob/71b1b7ce4adf7bea2ddacfc683a69906d6acd6ae/GSDKit/Tests/GSDSyncTests/SyncEngineSessionFenceTests.swift
[switch-tests]: https://github.com/davidpovarsky/gsd-iosapp/blob/71b1b7ce4adf7bea2ddacfc683a69906d6acd6ae/GSDKit/Tests/GSDSyncTests/AccountSwitchTests.swift
[session-report]: SESSION_IDENTITY_OBSERVATION_20261124.md
[connectivity-report]: SYNC_CONNECTIVITY_SCHEDULING_20261124.md
[public-log]: evidence/cloud-20261124/public-e2e.txt
[public-receipt]: evidence/cloud-20261124/public-e2e.json
[oauth-report]: OAUTH_WEB_LOCALIZATION_ACCEPTANCE_20261124.md
[calendar-report]: BACKUP_CALENDAR_ACCEPTANCE_20261124.md
[recovery-report]: https://github.com/davidpovarsky/gsd-iosapp/blob/540bde78d1eb7b90de9eb12d20d319d1c439f1f4/docs/ai-agent/NONEMPTY_BACKUP_RECOVERY_ACCEPTANCE_20261124.md
[health-receipt]: evidence/cloud-functional-20261124/closure-health.json

[later-auth-report]: https://app.asana.com/1/1219597879016953/project/1220770501963372/task/1220825972434803
