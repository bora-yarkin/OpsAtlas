#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only
# ruff: noqa: E402

from __future__ import annotations

import json
import hashlib
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from uuid import UUID, uuid5

from sqlalchemy import delete, func, inspect, select, text
from sqlalchemy.orm import Session

# Allow `python scripts/seed_db.py` to import the sibling `app` package.
BACKEND_ROOT = Path(__file__).resolve().parents[1]
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))

from app.core.config import settings
from app.core.db import Base
from app.core.db import init_db
from app.core.db import SessionLocal, engine
from app.core.auth.policy import hash_refresh_token
from app.core.auth.security import hash_password, verify_password
from app.modules.analytics.models import Event
from app.modules.admin.models import (
    BrandingDraft,
    BrandingRevision,
    BrandingSettings,
    CustomRole,
    OrganizationAuditEvent,
    OrganizationItemLink,
    OrganizationItem,
    OrganizationUnit,
)
from app.modules.admin import service as admin_service
from app.modules.auth.models import (
    AuthSessionPolicy,
    User,
    UserDashboardPreference,
    UserNotificationPreference,
    UserNotificationPreferenceAudit,
    UserSecurityState,
    UserSession,
)
from app.modules.incidents.models import (
    Incident,
    IncidentActionItem,
    IncidentActionReminder,
    IncidentImpactService,
    IncidentLink,
    IncidentMeta,
    IncidentProfile,
    IncidentStatusTransition,
    IncidentStatusUpdate,
    IncidentTemplate,
    IncidentTimeline,
    IncidentTimelineMeta,
)
from app.modules.kb.models import (
    Doc,
    DocComment,
    DocMentionNotification,
    DocMeta,
    DocReviewAssignment,
    DocVersion,
    Folder,
    KbSpacePolicy,
)
from app.modules.media.models import (
    MediaAsset,
    MediaAssetMeta,
    MediaAttachment,
    MediaUsage,
)
from app.modules.sop.models import (
    Sop,
    SopApprovalDecision,
    SopApprovalStage,
    SopMeta,
    SopReminderDispatch,
    SopRun,
    SopRunFollowUp,
    SopRunSchedule,
    SopRunStep,
    SopStep,
    SopStepEvidenceRule,
    SopStepMeta,
)
from app.modules.localization.models import (
    LocalizationBundle,
    LocalizationLanguage,
    LocalizationTranslationJob,
    LocalizationTranslationSetting,
    LocalizationTranslationSource,
    LocalizationTranslationVariant,
    OrganizationLocalizationSetting,
    UserLocalizationPreference,
)
from app.modules.localization import service as localization_service
from app.modules.spaces.models import Space
from app.modules.tasks.models import (
    Task,
    TaskComment,
    TaskExecutionProfile,
    TaskReminderDispatch,
)


SEED_NS = UUID("0b11a516-0f80-4f49-9d70-7b342d3097fb")
BASE_TS = datetime(2026, 2, 26, 12, 0, tzinfo=timezone.utc)
LOCALIZATION_LANG_CODES: tuple[str, str, str] = ("en", "tr", "de")
_META_KEY_SANITIZE_RE = re.compile(r"[^a-z0-9]+")
_TOKEN_RE = re.compile(r"[A-Za-z][A-Za-z0-9_-]*")
_PHRASE_REPLACEMENTS: dict[str, tuple[tuple[str, str], ...]] = {
    "tr": (
        ("Incident Commander", "Olay Komutanı"),
        ("API Release Checklist", "API Sürüm Kontrol Listesi"),
        ("Rollback API Release", "API Sürümünü Geri Alma"),
        ("Customer Support", "Müşteri Desteği"),
        ("Store Ops", "Mağaza Operasyonları"),
    ),
    "de": (
        ("Incident Commander", "Incident Commander"),
        ("API Release Checklist", "API-Release-Checkliste"),
        ("Rollback API Release", "API-Release-Rollback"),
        ("Customer Support", "Kundensupport"),
        ("Store Ops", "Store Ops"),
    ),
}
_EXACT_TRANSLATIONS: dict[str, dict[str, str]] = {
    "tr": {
        "Incident Commander Quickstart": "Olay Komutanı Hızlı Başlangıç",
        "API Release Checklist": "API Sürüm Kontrol Listesi",
        "Postgres Restore Drill Notes": "Postgres Geri Yükleme Tatbikat Notları",
        "Service Dependency Map": "Servis Bağımlılık Haritası",
        "New Engineer Onboarding: Week 1": "Yeni Mühendis Oryantasyonu: 1. Hafta",
        "Rollback API Release": "API Sürümünü Geri Alma",
        "Rotate Database Credentials": "Veritabanı Kimlik Bilgilerini Döndür",
        "API latency spike after release 2026.02.24": "2026.02.24 sürümünden sonra API gecikme sıçraması",
        "Backup proxy timeouts during snapshot browsing": "Anlık görüntü gezintisi sırasında yedekleme proxy zaman aşımları",
        "Store Opening Checklist": "Mağaza Açılış Kontrol Listesi",
        "Store Closing and Cash Drop": "Mağaza Kapanış ve Kasa Devir",
        "POS Terminal Daily Health Check": "POS Terminal Günlük Sağlık Kontrolü",
        "Cycle Count Escalation Guide": "Döngü Sayımı Eskalasyon Rehberi",
        "Replace POS Receipt Printer": "POS Fiş Yazıcısını Değiştir",
        "Inventory Recount Escalation": "Envanter Yeniden Sayım Eskalasyonu",
        "POS sync backlog in EU region stores": "AB bölgesi mağazalarında POS senkronizasyon yığılması",
        "Tier-1 Escalation Routing": "Seviye-1 Eskalasyon Yönlendirmesi",
        "Refund Eligibility Matrix": "İade Uygunluk Matrisi",
        "Chat Macros for High-Volume Periods": "Yüksek Hacimli Dönemler için Sohbet Makroları",
        "QA Escalation Review Rubric": "QA Eskalasyon İnceleme Ölçütü",
        "After-hours Escalation Handoff": "Mesai Dışı Eskalasyon Devir Süreci",
        "Refund Delay Triage": "İade Gecikmesi Triajı",
        "Refund queue delay due to payment gateway timeouts": "Ödeme ağ geçidi zaman aşımları nedeniyle iade kuyruğu gecikmesi",
        "Daily Ops Brief": "Günlük Operasyon Özeti",
        "Daily Readiness Walk": "Günlük Hazırlık Turu",
        "Lane 4 printer validation failure after replacement": "Değişim sonrası 4. kasada yazıcı doğrulama hatası",
        "Confirm rollback criteria": "Geri alma kriterlerini doğrula",
        "Pause further deployments": "Yeni dağıtımları duraklat",
        "Deploy previous artifact": "Önceki artefaktı dağıt",
        "Run smoke tests": "Smoke testlerini çalıştır",
        "Monitor stabilization": "Stabilizasyonu izle",
        "Document incident context": "Olay bağlamını dokümante et",
        "Create new DB credentials": "Yeni DB kimlik bilgileri oluştur",
        "Update application secret": "Uygulama sırrını güncelle",
        "Restart application workers": "Uygulama workerlarını yeniden başlat",
        "Validate database connectivity": "Veritabanı bağlantısını doğrula",
        "Revoke previous credentials": "Önceki kimlik bilgilerini iptal et",
        "Notify cashier and pause lane": "Kasiyeri bilgilendir ve kasayı duraklat",
        "Confirm terminal ID": "Terminal kimliğini doğrula",
        "Swap printer hardware": "Yazıcı donanımını değiştir",
        "Run test print": "Test çıktısı al",
        "Resume lane and log replacement": "Kasayı yeniden aç ve değişimi kaydet",
        "Perform second count with a different associate": "Farklı bir görevli ile ikinci sayımı yap",
        "Check recent transfers and returns": "Son transfer ve iadeleri kontrol et",
        "Capture discrepancy evidence": "Tutarsızlık kanıtlarını topla",
        "Escalate by threshold": "Eşik değerine göre eskale et",
        "Confirm urgency and impact": "Aciliyet ve etkiyi doğrula",
        "Collect reproduction and account identifiers": "Tekrar üretim adımlarını ve hesap kimliklerini topla",
        "Page on-call team": "Nöbetçi ekibi çağır",
        "Send customer acknowledgement": "Müşteriye alındı bildirimi gönder",
        "Document handoff in ticket": "Devir bilgisini ticket'a yaz",
        "Verify refund was approved": "İadenin onaylandığını doğrula",
        "Check processor settlement status": "İşleyici mutabakat durumunu kontrol et",
        "Validate customer payment method type": "Müşteri ödeme yöntemi türünü doğrula",
        "Escalate with evidence if past SLA": "SLA aşıldıysa kanıtlarla eskale et",
        "Confirm shift plan": "Vardiya planını doğrula",
        "Run hardware health checks": "Donanım sağlık kontrollerini çalıştır",
        "Publish readiness update": "Hazırlık güncellemesini yayınla",
        "Cap analytics query fan-out before the next release": "Bir sonraki sürümden önce analitik sorgu fan-out'unu sınırla",
        "Add backup proxy timeout telemetry to the operations dashboard": "Operasyon paneline yedekleme proxy zaman aşımı telemetrisini ekle",
        "Roll out new receipt printer asset labels for Austin pilot lanes": "Austin pilot kasaları için yeni fiş yazıcı envanter etiketlerini devreye al",
        "Review weekend opening checklist with Austin shift leads": "Austin vardiya liderleriyle hafta sonu açılış kontrol listesini gözden geçir",
        "Refresh refund delay macro wording before spring sale launch": "Bahar kampanyası öncesi iade gecikmesi makro metnini güncelle",
        "Audit escalation QA samples for week 9": "9. hafta için eskalasyon QA örneklerini denetle",
        "OpsAtlas Companywide Operations": "OpsAtlas Şirket Geneli Operasyonlar",
        "OpsAtlas Retail Store Operations": "OpsAtlas Retail Mağaza Operasyonları",
        "EMEA North Management": "EMEA Kuzey Yönetimi",
        "EMEA Central Management": "EMEA Merkez Yönetimi",
        "Americas Management": "Amerikalar Yönetimi",
        "Runbooks": "Runbook'lar",
        "Deployments": "Dağıtımlar",
        "Databases": "Veritabanları",
        "Architecture": "Mimari",
        "Onboarding": "Oryantasyon",
        "Store Operations": "Mağaza Operasyonları",
        "Operations": "Operasyonlar",
        "Opening": "Açılış",
        "Closing": "Kapanış",
        "Hardware": "Donanım",
        "Inventory": "Envanter",
        "Customer Support": "Müşteri Desteği",
        "Escalations": "Eskalasyonlar",
        "Billing": "Faturalama",
        "Macros": "Makrolar",
        "Quality Reviews": "Kalite İncelemeleri",
        "Playbooks": "Playbook'lar",
        "Release Manager": "Sürüm Yöneticisi",
        "Regional Director": "Bölge Direktörü",
        "Shift Lead": "Vardiya Lideri",
        "Support QA": "Destek QA",
        "Store Manager": "Mağaza Müdürü",
        "Merchandising Planner": "Merchandising Planlayıcısı",
        "EMEA North Region": "EMEA Kuzey Bölgesi",
        "EMEA Central Region": "EMEA Merkez Bölgesi",
        "Americas Region": "Amerikalar Bölgesi",
        "Global Ops Command Center": "Küresel Operasyon Komuta Merkezi",
        "Berlin Mitte Flagship Store": "Berlin Mitte Amiral Mağazası",
        "Berlin Kurfuerstendamm Flagship Store": "Berlin Kurfürstendamm Amiral Mağazası",
        "Berlin East Side Gallery Store": "Berlin East Side Gallery Mağazası",
        "Munich Marienplatz Store": "Münih Marienplatz Mağazası",
        "Hamburg Jungfernstieg Store": "Hamburg Jungfernstieg Mağazası",
        "Paris Opera Store": "Paris Opera Mağazası",
        "Austin Domain Store": "Austin Domain Mağazası",
        "Seattle University Village Store": "Seattle University Village Mağazası",
        "Atlanta Lenox Store": "Atlanta Lenox Mağazası",
        "OpsAtlas Operations Cloud": "OpsAtlas Operasyon Bulutu",
        "Alert fired for API p95 > 1500ms for 5 minutes.": "API p95 > 1500ms uyarısı 5 dakika boyunca tetiklendi.",
        "Incident channel created. Release frozen pending triage.": "Olay kanalı oluşturuldu. Triaj tamamlanana kadar sürüm donduruldu.",
        "Latency linked to new analytics endpoint query path; DB CPU spiking.": "Gecikme yeni analitik endpoint sorgu yoluna bağlandı; DB CPU yükseliyor.",
        "Rollback completed to previous image; latency trending down.": "Geri alma önceki imaja tamamlandı; gecikme düşüş trendinde.",
        "Resolved after 20-minute monitoring window. Follow-up ticket opened for query limit.": "20 dakikalık izleme penceresi sonrası çözüldü. Sorgu limiti için takip ticket'ı açıldı.",
        "QA reported intermittent timeout on `/admin/backups/snapshots/{id}/tree`.": "QA, `/admin/backups/snapshots/{id}/tree` üzerinde aralıklı zaman aşımı bildirdi.",
        "Scoped to backup browsing endpoints; main app remains healthy.": "Sorun yedek gezinti endpoint'leriyle sınırlı; ana uygulama sağlıklı.",
        "Temporary mitigation documented; monitoring during test sessions.": "Geçici azaltım dokümante edildi; test oturumları boyunca izleme sürüyor.",
        "First report from Paris store: inventory sync age > 40 minutes.": "Paris mağazasından ilk bildirim: envanter senkron yaşı > 40 dakika.",
        "Confirmed issue across multiple EU stores; opened regional incident.": "Sorun birden fazla AB mağazasında doğrulandı; bölgesel olay açıldı.",
        "Store managers instructed to manually verify stock for serialized items.": "Mağaza müdürlerine seri numaralı ürünler için stokları manuel doğrulama talimatı verildi.",
        "Payments gateway timeout rate increased; retry workers lagging.": "Ödeme ağ geçidi zaman aşımı oranı arttı; yeniden deneme workerları geride.",
        "Retry concurrency temporarily increased; backlog draining.": "Yeniden deneme eşzamanlılığı geçici olarak artırıldı; yığılma azalıyor.",
        "Queue recovered. Drafted customer response macro for delayed confirmations.": "Kuyruk toparlandı. Gecikmeli onaylar için müşteri yanıt makrosu taslağı hazırlandı.",
        "Incident opened after readiness check uncovered a blocking issue.": "Hazırlık kontrolü engelleyici bir sorun ortaya çıkarınca olay açıldı.",
        "Mitigation applied and impacted workstream rerouted.": "Azaltım uygulandı ve etkilenen iş akışı yeniden yönlendirildi.",
        "Resolved after validation checks passed and handoff notes were published.": "Doğrulama kontrolleri geçip devir notları yayınlandıktan sonra çözüldü.",
        "Lane 4 resumed, but the printer self-test still failed after the swap.": "4. kasa yeniden açıldı ancak değişim sonrası yazıcı öz testi yine başarısız oldu.",
        "Escalated to field ops and opened follow-up for hardware inspection.": "Saha operasyonlarına eskale edildi ve donanım incelemesi için takip açıldı.",
        "Check error rate, p95 latency, and user impact.": "Hata oranını, p95 gecikmesini ve kullanıcı etkisini kontrol et.",
        "Freeze the release queue and notify the release channel.": "Sürüm kuyruğunu dondur ve sürüm kanalını bilgilendir.",
        "Use the last known good image tag in production deploy workflow.": "Üretim dağıtım akışında son bilinen iyi imaj etiketini kullan.",
        "Validate `/health`, auth login, and spaces list.": "`/health`, auth login ve alanlar listesini doğrula.",
        "Watch 5xx, latency, DB pool saturation for 15 minutes.": "5xx, gecikme ve DB havuz doygunluğunu 15 dakika izle.",
        "Open or update incident with rollback reason and follow-ups.": "Geri alma nedeni ve takiplerle olayı aç veya güncelle.",
        "Generate a new password in the team vault and create DB user or alter password.": "Ekip kasasında yeni parola üret ve DB kullanıcısı oluştur ya da parolayı değiştir.",
        "Rotate secret in deployment environment without removing previous access yet.": "Önceki erişimi henüz kaldırmadan dağıtım ortamındaki sırrı döndür.",
        "Roll restart to ensure all processes pick up the new secret.": "Tüm süreçlerin yeni sırrı alması için rolling restart yap.",
        "Run login flow and create a test record in staging/admin workflow.": "Login akışını çalıştır ve staging/admin akışında test kaydı oluştur.",
        "Disable old credentials after successful verification window.": "Doğrulama penceresi başarıyla tamamlandıktan sonra eski kimlik bilgilerini devre dışı bırak.",
        "Move customers to adjacent lane before disconnecting hardware.": "Donanımı ayırmadan önce müşterileri yan kasaya yönlendir.",
        "Record lane and terminal ID for maintenance log.": "Bakım kaydı için kasa ve terminal kimliğini kaydet.",
        "Disconnect power/USB, replace unit, and load paper roll.": "Güç/USB bağlantısını kes, birimi değiştir ve kağıt rulosunu yükle.",
        "Use POS diagnostics to verify print quality and cut operation.": "Yazdırma kalitesi ve kesme işlemini doğrulamak için POS tanılamayı kullan.",
        "Mark lane active and update hardware inventory sheet.": "Kasayı aktif işaretle ve donanım envanter çizelgesini güncelle.",
        "Use the same SKU set and location boundaries.": "Aynı SKU setini ve lokasyon sınırlarını kullan.",
        "Confirm pending receiving paperwork and return disposition.": "Bekleyen teslim evrakını ve iade durumunu doğrula.",
        "Photos, shelf labels, and transaction timestamps.": "Fotoğraflar, raf etiketleri ve işlem zaman damgaları.",
        "Notify area manager and loss prevention based on item class and variance.": "Ürün sınıfı ve farka göre bölge yöneticisini ve kayıp önlemeyi bilgilendir.",
        "Determine whether customer-blocking or revenue-impacting.": "Müşteriyi engelleyip engellemediğini veya geliri etkileyip etkilemediğini belirle.",
        "Include exact timestamps, account ID, and observed errors.": "Tam zaman damgalarını, hesap kimliğini ve gözlenen hataları ekle.",
        "Use current escalation policy and include a concise incident summary.": "Mevcut eskalasyon politikasını kullan ve kısa bir olay özeti ekle.",
        "Provide expected update window and reference number.": "Beklenen güncelleme penceresini ve referans numarasını ver.",
        "Capture who was paged and when.": "Kimin ne zaman çağrıldığını kaydet.",
        "Check ticket notes and approval actor.": "Ticket notlarını ve onay veren kişiyi kontrol et.",
        "Look for pending, submitted, or failed status.": "Bekleyen, gönderilen veya başarısız durumları kontrol et.",
        "Bank transfer and card refunds have different posting windows.": "Banka transferi ve kart iadelerinin muhasebeleşme pencereleri farklıdır.",
        "Include order ID, processor reference, approval timestamp.": "Sipariş kimliği, işlemci referansı ve onay zaman damgasını ekle.",
        "Validate staffing coverage and confirm role handoffs.": "Personel kapsamını doğrula ve rol devirlerini onayla.",
        "Validate POS, network, and receipt printers.": "POS, ağ ve fiş yazıcılarını doğrula.",
        "Post current status and blockers to the operations channel.": "Mevcut durum ve engelleri operasyon kanalında paylaş.",
    },
    "de": {
        "Incident Commander Quickstart": "Incident-Commander Schnellstart",
        "API Release Checklist": "API-Release-Checkliste",
        "Postgres Restore Drill Notes": "Postgres-Wiederherstellungsübung Notizen",
        "Service Dependency Map": "Service-Abhängigkeitskarte",
        "New Engineer Onboarding: Week 1": "Onboarding neuer Ingenieure: Woche 1",
        "Rollback API Release": "API-Release-Rollback",
        "Rotate Database Credentials": "Datenbank-Zugangsdaten rotieren",
        "API latency spike after release 2026.02.24": "API-Latenzspitze nach Release 2026.02.24",
        "Backup proxy timeouts during snapshot browsing": "Backup-Proxy-Timeouts beim Snapshot-Browsing",
        "Store Opening Checklist": "Filialöffnungs-Checkliste",
        "Store Closing and Cash Drop": "Filialschluss und Kassenabschluss",
        "POS Terminal Daily Health Check": "POS-Terminal täglicher Gesundheitscheck",
        "Cycle Count Escalation Guide": "Leitfaden zur Eskalation bei Zykluszählungen",
        "Replace POS Receipt Printer": "POS-Belegdrucker austauschen",
        "Inventory Recount Escalation": "Eskalation bei Inventur-Nachzählung",
        "POS sync backlog in EU region stores": "POS-Sync-Rückstand in Filialen der EU-Region",
        "Tier-1 Escalation Routing": "Tier-1-Eskalationsrouting",
        "Refund Eligibility Matrix": "Erstattungsberechtigungs-Matrix",
        "Chat Macros for High-Volume Periods": "Chat-Makros für Zeiten mit hohem Volumen",
        "QA Escalation Review Rubric": "QA-Eskalationsbewertungsraster",
        "After-hours Escalation Handoff": "Eskalationsübergabe außerhalb der Geschäftszeiten",
        "Refund Delay Triage": "Triage bei Erstattungsverzögerungen",
        "Refund queue delay due to payment gateway timeouts": "Verzögerung der Erstattungswarteschlange durch Payment-Gateway-Timeouts",
        "Daily Ops Brief": "Tägliches Ops-Briefing",
        "Daily Readiness Walk": "Täglicher Readiness-Rundgang",
        "Lane 4 printer validation failure after replacement": "Drucker-Validierungsfehler auf Kasse 4 nach Austausch",
        "Confirm rollback criteria": "Rollback-Kriterien bestätigen",
        "Pause further deployments": "Weitere Deployments pausieren",
        "Deploy previous artifact": "Vorheriges Artefakt deployen",
        "Run smoke tests": "Smoke-Tests ausführen",
        "Monitor stabilization": "Stabilisierung überwachen",
        "Document incident context": "Vorfallkontext dokumentieren",
        "Create new DB credentials": "Neue DB-Zugangsdaten erstellen",
        "Update application secret": "Anwendungs-Secret aktualisieren",
        "Restart application workers": "Anwendungs-Worker neu starten",
        "Validate database connectivity": "Datenbankverbindung validieren",
        "Revoke previous credentials": "Vorherige Zugangsdaten widerrufen",
        "Notify cashier and pause lane": "Kassierer informieren und Kasse pausieren",
        "Confirm terminal ID": "Terminal-ID bestätigen",
        "Swap printer hardware": "Druckerhardware austauschen",
        "Run test print": "Testdruck ausführen",
        "Resume lane and log replacement": "Kasse wieder aufnehmen und Austausch protokollieren",
        "Perform second count with a different associate": "Zweite Zählung mit anderer Person durchführen",
        "Check recent transfers and returns": "Letzte Transfers und Rückgaben prüfen",
        "Capture discrepancy evidence": "Nachweise für Abweichungen erfassen",
        "Escalate by threshold": "Nach Schwellenwert eskalieren",
        "Confirm urgency and impact": "Dringlichkeit und Auswirkung bestätigen",
        "Collect reproduction and account identifiers": "Reproduktionsschritte und Konto-IDs erfassen",
        "Page on-call team": "Bereitschaftsteam alarmieren",
        "Send customer acknowledgement": "Empfangsbestätigung an Kunden senden",
        "Document handoff in ticket": "Übergabe im Ticket dokumentieren",
        "Verify refund was approved": "Prüfen, ob Erstattung genehmigt wurde",
        "Check processor settlement status": "Abrechnungsstatus des Prozessors prüfen",
        "Validate customer payment method type": "Zahlungsmitteltyp des Kunden validieren",
        "Escalate with evidence if past SLA": "Bei SLA-Verstoß mit Nachweisen eskalieren",
        "Confirm shift plan": "Schichtplan bestätigen",
        "Run hardware health checks": "Hardware-Gesundheitschecks ausführen",
        "Publish readiness update": "Readiness-Update veröffentlichen",
        "Cap analytics query fan-out before the next release": "Analytics-Query-Fan-out vor dem nächsten Release begrenzen",
        "Add backup proxy timeout telemetry to the operations dashboard": "Backup-Proxy-Timeout-Telemetrie zum Operations-Dashboard hinzufügen",
        "Roll out new receipt printer asset labels for Austin pilot lanes": "Neue Asset-Labels für Belegdrucker in Austin-Pilotkassen ausrollen",
        "Review weekend opening checklist with Austin shift leads": "Wochenend-Öffnungscheckliste mit Austin-Schichtleitern prüfen",
        "Refresh refund delay macro wording before spring sale launch": "Formulierung der Erstattungsverzögerungs-Makros vor dem Frühlingsverkaufsstart aktualisieren",
        "Audit escalation QA samples for week 9": "QA-Eskalationsstichproben für Woche 9 auditieren",
        "OpsAtlas Companywide Operations": "OpsAtlas unternehmensweite Betriebsabläufe",
        "OpsAtlas Retail Store Operations": "OpsAtlas Retail Filialbetrieb",
        "EMEA North Management": "EMEA Nord-Management",
        "EMEA Central Management": "EMEA Zentral-Management",
        "Americas Management": "Amerika-Management",
        "Runbooks": "Runbooks",
        "Deployments": "Deployments",
        "Databases": "Datenbanken",
        "Architecture": "Architektur",
        "Onboarding": "Onboarding",
        "Store Operations": "Filialbetrieb",
        "Operations": "Betrieb",
        "Opening": "Öffnung",
        "Closing": "Schließung",
        "Hardware": "Hardware",
        "Inventory": "Inventar",
        "Customer Support": "Kundensupport",
        "Escalations": "Eskalationen",
        "Billing": "Abrechnung",
        "Macros": "Makros",
        "Quality Reviews": "Qualitätsprüfungen",
        "Playbooks": "Playbooks",
        "Release Manager": "Release-Manager",
        "Regional Director": "Regionaldirektor",
        "Shift Lead": "Schichtleiter",
        "Support QA": "Support-QA",
        "Store Manager": "Filialleiter",
        "Merchandising Planner": "Merchandising-Planer",
        "EMEA North Region": "EMEA Nordregion",
        "EMEA Central Region": "EMEA Zentralregion",
        "Americas Region": "Amerikas-Region",
        "Global Ops Command Center": "Globales Ops-Kommandocenter",
        "Berlin Mitte Flagship Store": "Berlin Mitte Flagship-Store",
        "Berlin Kurfuerstendamm Flagship Store": "Berlin Kurfürstendamm Flagship-Store",
        "Berlin East Side Gallery Store": "Berlin East Side Gallery Store",
        "Munich Marienplatz Store": "München Marienplatz Store",
        "Hamburg Jungfernstieg Store": "Hamburg Jungfernstieg Store",
        "Paris Opera Store": "Paris Opera Store",
        "Austin Domain Store": "Austin Domain Store",
        "Seattle University Village Store": "Seattle University Village Store",
        "Atlanta Lenox Store": "Atlanta Lenox Store",
        "OpsAtlas Operations Cloud": "OpsAtlas Operations Cloud",
        "Alert fired for API p95 > 1500ms for 5 minutes.": "Alarm ausgelöst: API p95 > 1500ms für 5 Minuten.",
        "Incident channel created. Release frozen pending triage.": "Incident-Kanal erstellt. Release bis zur Triage eingefroren.",
        "Latency linked to new analytics endpoint query path; DB CPU spiking.": "Latenz mit neuem Analytics-Endpoint-Abfragepfad verknüpft; DB-CPU steigt stark an.",
        "Rollback completed to previous image; latency trending down.": "Rollback auf vorheriges Image abgeschlossen; Latenz sinkt.",
        "Resolved after 20-minute monitoring window. Follow-up ticket opened for query limit.": "Nach 20-minütigem Monitoring behoben. Follow-up-Ticket für Query-Limit eröffnet.",
        "QA reported intermittent timeout on `/admin/backups/snapshots/{id}/tree`.": "QA meldete intermittierenden Timeout auf `/admin/backups/snapshots/{id}/tree`.",
        "Scoped to backup browsing endpoints; main app remains healthy.": "Auf Backup-Browsing-Endpunkte eingegrenzt; Hauptanwendung bleibt gesund.",
        "Temporary mitigation documented; monitoring during test sessions.": "Temporäre Gegenmaßnahme dokumentiert; Monitoring während Testsitzungen.",
        "First report from Paris store: inventory sync age > 40 minutes.": "Erste Meldung aus dem Paris-Store: Inventar-Sync-Alter > 40 Minuten.",
        "Confirmed issue across multiple EU stores; opened regional incident.": "Problem in mehreren EU-Stores bestätigt; regionalen Incident eröffnet.",
        "Store managers instructed to manually verify stock for serialized items.": "Store-Manager wurden angewiesen, Bestand für serialisierte Artikel manuell zu prüfen.",
        "Payments gateway timeout rate increased; retry workers lagging.": "Timeout-Rate des Payment-Gateways gestiegen; Retry-Worker hängen hinterher.",
        "Retry concurrency temporarily increased; backlog draining.": "Retry-Konkurrenz vorübergehend erhöht; Rückstau baut sich ab.",
        "Queue recovered. Drafted customer response macro for delayed confirmations.": "Warteschlange erholt. Kundenantwort-Makro für verzögerte Bestätigungen entworfen.",
        "Incident opened after readiness check uncovered a blocking issue.": "Incident eröffnet, nachdem der Readiness-Check ein blockierendes Problem aufdeckte.",
        "Mitigation applied and impacted workstream rerouted.": "Gegenmaßnahme angewendet und betroffener Arbeitsstrom umgeleitet.",
        "Resolved after validation checks passed and handoff notes were published.": "Behoben, nachdem Validierungsprüfungen bestanden und Übergabenotizen veröffentlicht wurden.",
        "Lane 4 resumed, but the printer self-test still failed after the swap.": "Kasse 4 wurde fortgesetzt, aber der Drucker-Selbsttest schlug nach dem Austausch weiterhin fehl.",
        "Escalated to field ops and opened follow-up for hardware inspection.": "An Field Ops eskaliert und Follow-up für Hardware-Inspektion eröffnet.",
        "Check error rate, p95 latency, and user impact.": "Fehlerrate, p95-Latenz und Nutzerauswirkung prüfen.",
        "Freeze the release queue and notify the release channel.": "Release-Warteschlange einfrieren und Release-Kanal benachrichtigen.",
        "Use the last known good image tag in production deploy workflow.": "Im Produktions-Deploy-Workflow das zuletzt bekannte gute Image-Tag verwenden.",
        "Validate `/health`, auth login, and spaces list.": "`/health`, Auth-Login und Bereichsliste validieren.",
        "Watch 5xx, latency, DB pool saturation for 15 minutes.": "5xx, Latenz und DB-Pool-Sättigung 15 Minuten beobachten.",
        "Open or update incident with rollback reason and follow-ups.": "Incident mit Rollback-Grund und Follow-ups öffnen oder aktualisieren.",
        "Generate a new password in the team vault and create DB user or alter password.": "Neues Passwort im Team-Vault erzeugen und DB-Benutzer erstellen oder Passwort ändern.",
        "Rotate secret in deployment environment without removing previous access yet.": "Secret in der Deployment-Umgebung rotieren, ohne den vorherigen Zugriff sofort zu entfernen.",
        "Roll restart to ensure all processes pick up the new secret.": "Rolling-Restart durchführen, damit alle Prozesse das neue Secret übernehmen.",
        "Run login flow and create a test record in staging/admin workflow.": "Login-Flow ausführen und Testdatensatz im Staging/Admin-Workflow erstellen.",
        "Disable old credentials after successful verification window.": "Alte Zugangsdaten nach erfolgreichem Verifikationsfenster deaktivieren.",
        "Move customers to adjacent lane before disconnecting hardware.": "Kunden vor dem Trennen der Hardware auf benachbarte Kasse umleiten.",
        "Record lane and terminal ID for maintenance log.": "Kassen- und Terminal-ID für Wartungsprotokoll erfassen.",
        "Disconnect power/USB, replace unit, and load paper roll.": "Strom/USB trennen, Gerät austauschen und Papierrolle einlegen.",
        "Use POS diagnostics to verify print quality and cut operation.": "POS-Diagnose verwenden, um Druckqualität und Schneidefunktion zu prüfen.",
        "Mark lane active and update hardware inventory sheet.": "Kasse als aktiv markieren und Hardware-Inventarliste aktualisieren.",
        "Use the same SKU set and location boundaries.": "Dasselbe SKU-Set und dieselben Standortgrenzen verwenden.",
        "Confirm pending receiving paperwork and return disposition.": "Ausstehende Wareneingangsunterlagen und Rückgabe-Status bestätigen.",
        "Photos, shelf labels, and transaction timestamps.": "Fotos, Regaletiketten und Transaktionszeitstempel.",
        "Notify area manager and loss prevention based on item class and variance.": "Bereichsleiter und Loss Prevention je nach Artikelklasse und Abweichung benachrichtigen.",
        "Determine whether customer-blocking or revenue-impacting.": "Feststellen, ob kundenblockierend oder umsatzrelevant.",
        "Include exact timestamps, account ID, and observed errors.": "Exakte Zeitstempel, Konto-ID und beobachtete Fehler angeben.",
        "Use current escalation policy and include a concise incident summary.": "Aktuelle Eskalationsrichtlinie verwenden und kurze Incident-Zusammenfassung hinzufügen.",
        "Provide expected update window and reference number.": "Erwartetes Update-Fenster und Referenznummer angeben.",
        "Capture who was paged and when.": "Erfassen, wer wann gepaged wurde.",
        "Check ticket notes and approval actor.": "Ticket-Notizen und Freigabeakteur prüfen.",
        "Look for pending, submitted, or failed status.": "Nach Status ausstehend, eingereicht oder fehlgeschlagen suchen.",
        "Bank transfer and card refunds have different posting windows.": "Banküberweisungen und Kartenerstattungen haben unterschiedliche Buchungsfenster.",
        "Include order ID, processor reference, approval timestamp.": "Bestell-ID, Prozessorreferenz und Freigabezeitstempel angeben.",
        "Validate staffing coverage and confirm role handoffs.": "Personalabdeckung validieren und Rollenübergaben bestätigen.",
        "Validate POS, network, and receipt printers.": "POS, Netzwerk und Belegdrucker validieren.",
        "Post current status and blockers to the operations channel.": "Aktuellen Status und Blocker im Operations-Kanal posten.",
    },
}
_WORD_REPLACEMENTS: dict[str, dict[str, str]] = {
    "tr": {
        "incident": "olay",
        "incidents": "olaylar",
        "task": "görev",
        "tasks": "görevler",
        "checklist": "kontrol listesi",
        "release": "sürüm",
        "rollback": "geri alma",
        "document": "doküman",
        "documents": "dokümanlar",
        "summary": "özet",
        "status": "durum",
        "open": "açık",
        "closed": "kapalı",
        "resolved": "çözüldü",
        "space": "alan",
        "spaces": "alanlar",
        "store": "mağaza",
        "support": "destek",
        "monitoring": "izleme",
        "queue": "kuyruk",
        "retry": "yeniden dene",
        "service": "servis",
        "health": "sağlık",
        "policy": "politika",
        "review": "gözden geçirme",
        "approval": "onay",
        "template": "şablon",
        "timeline": "zaman çizelgesi",
        "note": "not",
        "notes": "notlar",
        "comment": "yorum",
        "comments": "yorumlar",
        "created": "oluşturuldu",
        "updated": "güncellendi",
    },
    "de": {
        "incident": "vorfall",
        "incidents": "vorfälle",
        "task": "aufgabe",
        "tasks": "aufgaben",
        "checklist": "checkliste",
        "release": "release",
        "rollback": "rollback",
        "document": "dokument",
        "documents": "dokumente",
        "summary": "zusammenfassung",
        "status": "status",
        "open": "offen",
        "closed": "geschlossen",
        "resolved": "gelöst",
        "space": "bereich",
        "spaces": "bereiche",
        "store": "filiale",
        "support": "support",
        "monitoring": "monitoring",
        "queue": "warteschlange",
        "retry": "wiederholen",
        "service": "dienst",
        "health": "gesundheit",
        "policy": "richtlinie",
        "review": "pruefung",
        "approval": "freigabe",
        "template": "vorlage",
        "timeline": "zeitachse",
        "note": "notiz",
        "notes": "notizen",
        "comment": "kommentar",
        "comments": "kommentare",
        "created": "erstellt",
        "updated": "aktualisiert",
    },
}
_PROTECTED_FRAGMENT_RE = re.compile(
    r"`[^`]+`|https?://[^\s)]+|(?:^|\s)(/[A-Za-z0-9_./{}?=&-]+)"
)


def seed_uuid(*parts: str) -> str:
    return str(uuid5(SEED_NS, "::".join(parts)))


def ts(days_ago: int = 0, hours: int = 0, minutes: int = 0) -> datetime:
    return BASE_TS - timedelta(days=days_ago, hours=hours, minutes=minutes)


def _seed_refresh_token_hash(*parts: str) -> str:
    return hash_refresh_token("::".join(("seed-refresh", *parts)))


def _branding_snapshot(
    *,
    company_name: str,
    application_title: str,
    application_short_name: str,
    web_description: str,
    apple_web_app_title: str,
    logo_url: str | None,
    light_logo_url: str | None,
    dark_logo_url: str | None,
    favicon_url: str | None,
    login_background_url: str | None,
    light_seed_hex: str | None,
    dark_accent_hex: str | None,
    dark_bg_hex: str | None,
    browser_theme_hex: str | None,
    install_background_hex: str | None,
) -> dict[str, Any]:
    return {
        "company_name": company_name,
        "application_title": application_title,
        "application_short_name": application_short_name,
        "web_description": web_description,
        "apple_web_app_title": apple_web_app_title,
        "logo_url": logo_url,
        "light_logo_url": light_logo_url,
        "dark_logo_url": dark_logo_url,
        "favicon_url": favicon_url,
        "login_background_url": login_background_url,
        "light_seed_hex": light_seed_hex,
        "dark_accent_hex": dark_accent_hex,
        "dark_bg_hex": dark_bg_hex,
        "browser_theme_hex": browser_theme_hex,
        "install_background_hex": install_background_hex,
    }


def _source_key(content_kind: str, content_id: str, field_key: str) -> str:
    basis = f"{content_kind}|{content_id}|{field_key}"
    return hashlib.sha1(basis.encode("utf-8")).hexdigest()


def _text_hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _decode_json_map(raw: str | None) -> dict[str, object]:
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except Exception:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _translation_meta_fields(meta: dict[str, object]) -> dict[str, str]:
    fields: dict[str, str] = {}
    for raw_key, raw_value in meta.items():
        if not isinstance(raw_value, str):
            continue
        value = raw_value.strip()
        if not value:
            continue
        base_key = str(raw_key).strip().lower()
        if not base_key:
            continue
        normalized_key = _META_KEY_SANITIZE_RE.sub("_", base_key).strip("_")
        if not normalized_key:
            continue
        fields[f"meta.{normalized_key[:96]}"] = value
    return fields


def _replace_words(text: str, mapping: dict[str, str]) -> str:
    def repl(match: re.Match[str]) -> str:
        token = match.group(0)
        mapped = mapping.get(token.lower())
        if mapped is None:
            return token
        if token.isupper():
            return mapped.upper()
        if token[:1].isupper():
            return mapped[:1].upper() + mapped[1:]
        return mapped

    return _TOKEN_RE.sub(repl, text)


def _protect_fragments(text: str) -> tuple[str, dict[str, str]]:
    replacements: dict[str, str] = {}

    def repl(match: re.Match[str]) -> str:
        token = f"[[PROTECTED_{len(replacements)}]]"
        fragment = match.group(0)
        replacements[token] = fragment
        return token

    protected = _PROTECTED_FRAGMENT_RE.sub(repl, text)
    return protected, replacements


def _restore_fragments(text: str, replacements: dict[str, str]) -> str:
    restored = text
    for token, fragment in replacements.items():
        restored = restored.replace(token, fragment)
    return restored


def _translate_line(line: str, language_code: str) -> str:
    if not line.strip():
        return line
    code = language_code.strip().lower()
    exact = _EXACT_TRANSLATIONS.get(code, {})

    leading_ws = line[: len(line) - len(line.lstrip())]
    trailing_ws = line[len(line.rstrip()) :]
    core = line.strip()

    markdown_prefix = ""
    prefix_match = re.match(r"^(#{1,6}\s+|-\s+|>\s+)", core)
    if prefix_match is not None:
        markdown_prefix = prefix_match.group(1)
        core = core[len(markdown_prefix) :].strip()

    if core in exact:
        return f"{leading_ws}{markdown_prefix}{exact[core]}{trailing_ws}"

    protected, replacements = _protect_fragments(core)
    translated = protected
    for source_phrase, target_phrase in _PHRASE_REPLACEMENTS.get(code, ()):
        translated = translated.replace(source_phrase, target_phrase)
    translated = _replace_words(translated, _WORD_REPLACEMENTS.get(code, {}))
    translated = _restore_fragments(translated, replacements)
    return f"{leading_ws}{markdown_prefix}{translated}{trailing_ws}"


def seed_translate_text(text: str, language_code: str) -> str:
    base = text.strip()
    if not base:
        return ""
    code = language_code.strip().lower()
    if code == "en":
        return base

    exact = _EXACT_TRANSLATIONS.get(code, {})
    if base in exact:
        return exact[base]
    lines = base.splitlines()
    translated_lines = [_translate_line(line, code) for line in lines]
    return "\n".join(translated_lines)


def upsert_translation_variants_for_fields(
    db: Session,
    *,
    content_kind: str,
    content_id: str,
    fields: dict[str, str | None],
    source_language_code: str = "en",
    actor_user_id: str | None = None,
) -> int:
    normalized_kind = content_kind.strip().lower()
    normalized_id = str(content_id).strip()
    source_code = source_language_code.strip().lower() or "en"
    if not normalized_kind or not normalized_id:
        return 0
    touched = 0
    for raw_field_key, raw_text in fields.items():
        field_key = str(raw_field_key).strip().lower()
        if not field_key or raw_text is None:
            continue
        source_text = str(raw_text).strip()
        if not source_text:
            continue
        source_id = _source_key(normalized_kind, normalized_id, field_key)
        source_row = db.get(LocalizationTranslationSource, source_id)
        source_hash = _text_hash(source_text)
        if source_row is None:
            source_row = LocalizationTranslationSource(
                id=source_id,
                content_kind=normalized_kind,
                content_id=normalized_id,
                field_key=field_key,
                source_language_code=source_code,
                source_text=source_text,
                source_hash=source_hash,
                source_version=1,
                active=True,
                updated_by_user_id=actor_user_id,
            )
            db.add(source_row)
            db.flush()
        else:
            source_row.content_kind = normalized_kind
            source_row.content_id = normalized_id
            source_row.field_key = field_key
            source_row.source_language_code = source_code
            source_row.source_text = source_text
            source_row.source_hash = source_hash
            source_row.source_version = 1
            source_row.active = True
            source_row.updated_by_user_id = actor_user_id

        for language_code in LOCALIZATION_LANG_CODES:
            translated_text = seed_translate_text(source_text, language_code)
            variant_id = seed_uuid(
                "localization-variant",
                normalized_kind,
                normalized_id,
                field_key,
                language_code,
            )
            variant = db.get(LocalizationTranslationVariant, variant_id)
            if variant is None:
                variant = LocalizationTranslationVariant(id=variant_id)
                db.add(variant)
            variant.source_id = source_row.id
            variant.content_kind = normalized_kind
            variant.content_id = normalized_id
            variant.field_key = field_key
            variant.language_code = language_code
            variant.source_language_code = source_code
            variant.source_version = int(source_row.source_version or 1)
            variant.translated_text = translated_text
            variant.status = "approved"
            variant.confidence = 1.0 if language_code == source_code else 0.88
            variant.provider = "seed"
            variant.model = "seed-localize-v1"
            variant.translated_at = BASE_TS
            variant.reviewed_by_user_id = actor_user_id
            variant.reviewed_at = BASE_TS
            variant.locked = False
            variant.last_error = None
        touched += 1
    return touched


def _seed_bundle_payload() -> dict[str, dict[str, object]]:
    root = BACKEND_ROOT.parent
    candidates = sorted(
        root.glob("localization_arb_bundles_*.json"),
        key=lambda item: item.stat().st_mtime,
        reverse=True,
    )
    for candidate in candidates:
        try:
            parsed = json.loads(candidate.read_text(encoding="utf-8"))
        except Exception:
            continue
        bundles_raw = parsed.get("bundles")
        if not isinstance(bundles_raw, dict):
            continue
        bundles: dict[str, dict[str, object]] = {}
        for code in LOCALIZATION_LANG_CODES:
            entries = bundles_raw.get(code)
            if isinstance(entries, dict):
                bundles[code] = {str(k): v for k, v in entries.items()}
        if bundles:
            return bundles

    discovered = localization_service.discover_builtin_bundles()
    fallback: dict[str, dict[str, object]] = {}
    for code in LOCALIZATION_LANG_CODES:
        entries = discovered.get(code, {})
        fallback[code] = {str(k): str(v) for k, v in entries.items()}
    return fallback


def get_or_create_user(
    db: Session,
    *,
    email: str,
    name: str,
    global_role: str,
    password: str,
    meta: dict[str, Any] | None = None,
) -> User:
    user = db.scalar(select(User).where(User.email == email))
    if not user:
        user = User(
            id=seed_uuid("user", email), email=email, name=name, global_role=global_role
        )
        db.add(user)

    user.name = name
    user.global_role = global_role
    try:
        password_ok = bool(user.password_hash) and verify_password(
            password, user.password_hash
        )
    except Exception:
        password_ok = False
    if not password_ok:
        user.password_hash = hash_password(password)
    if meta is not None:
        user.meta_json = json.dumps(meta, ensure_ascii=False, separators=(",", ":"))
    if not user.created_at:
        user.created_at = ts(days_ago=60)
    return user


def get_or_create_space(
    db: Session,
    *,
    slug: str,
    name: str,
    created_at: datetime,
    region_code: str | None = None,
    meta: dict[str, Any] | None = None,
) -> Space:
    space = db.scalar(select(Space).where(Space.slug == slug))
    if not space:
        space = Space(
            id=seed_uuid("space", slug), slug=slug, name=name, created_at=created_at
        )
        db.add(space)
    space.slug = slug
    space.name = name
    space.region_code = region_code
    if meta is not None:
        space.meta_json = json.dumps(meta, ensure_ascii=False, separators=(",", ":"))
    space.created_at = created_at
    # Ensure parent row exists before dependent rows (members/docs/incidents).
    db.flush()
    return space


def upsert_space_member(
    db: Session,
    *,
    space_id: str,
    user_id: str,
    role: str,
) -> None:
    # Intentionally no-op: space visibility is organization item-link based.
    return None


def upsert_org_item_link(
    db: Session,
    *,
    parent_kind: str,
    parent_id: str,
    child_kind: str,
    child_id: str,
    grant_role: str,
    inherit_to_descendants: bool,
    active: bool,
) -> OrganizationItemLink:
    row = db.scalar(
        select(OrganizationItemLink).where(
            OrganizationItemLink.parent_kind == parent_kind,
            OrganizationItemLink.parent_id == parent_id,
            OrganizationItemLink.child_kind == child_kind,
            OrganizationItemLink.child_id == child_id,
        )
    )
    if not row:
        row = OrganizationItemLink(
            id=seed_uuid("org-item-link", parent_kind, parent_id, child_kind, child_id),
            parent_kind=parent_kind,
            parent_id=parent_id,
            child_kind=child_kind,
            child_id=child_id,
        )
        db.add(row)
    row.grant_role = grant_role
    row.inherit_to_descendants = inherit_to_descendants
    row.active = active
    return row


def get_or_create_folder(
    db: Session,
    *,
    space: Space,
    name: str,
    parent: Folder | None,
) -> Folder:
    path = f"{parent.path if parent else ''}/{name}".replace("//", "/")
    folder = db.scalar(
        select(Folder).where(Folder.space_id == space.id, Folder.path == path)
    )
    if not folder:
        folder = Folder(
            id=seed_uuid("folder", space.slug, path),
            space_id=space.id,
            parent_id=parent.id if parent else None,
            name=name,
            path=path,
        )
        db.add(folder)
    folder.space_id = space.id
    folder.parent_id = parent.id if parent else None
    folder.name = name
    folder.path = path
    # Self-referential FK (`parent_id`) can fail if parent/child are flushed together.
    db.flush()
    return folder


def get_or_create_doc(
    db: Session,
    *,
    space: Space,
    slug: str,
    title: str,
    folder: Folder | None,
    created_by: User,
    updated_by: User,
    content_md: str,
    status: str,
    created_at: datetime,
    updated_at: datetime,
    published_at: datetime | None,
    versions: list[dict],
) -> Doc:
    doc = db.scalar(select(Doc).where(Doc.space_id == space.id, Doc.slug == slug))
    if not doc:
        doc = Doc(
            id=seed_uuid("doc", space.slug, slug),
            space_id=space.id,
            slug=slug,
            title=title,
            folder_id=folder.id if folder else None,
            status=status,
            content_md=content_md,
            created_by=created_by.id,
            updated_by=updated_by.id,
            created_at=created_at,
            updated_at=updated_at,
            published_at=published_at,
        )
        db.add(doc)

    doc.space_id = space.id
    doc.folder_id = folder.id if folder else None
    doc.title = title
    doc.slug = slug
    doc.status = status
    doc.content_md = content_md
    doc.created_by = created_by.id
    doc.updated_by = updated_by.id
    doc.created_at = created_at
    doc.updated_at = updated_at
    doc.published_at = published_at

    # Persist doc before inserting doc_versions that reference it.
    db.flush()

    for idx, version in enumerate(versions, start=1):
        ver_id = seed_uuid("doc-version", space.slug, slug, str(idx))
        dv = db.get(DocVersion, ver_id)
        if not dv:
            dv = DocVersion(id=ver_id, doc_id=doc.id)
            db.add(dv)
        dv.doc_id = doc.id
        dv.title = version["title"]
        dv.content_md = version["content_md"]
        dv.created_by = version["created_by"].id
        dv.created_at = version["created_at"]

    return doc


def get_or_create_sop(
    db: Session,
    *,
    space: Space,
    folder: Folder | None = None,
    slug: str,
    title: str,
    overview_md: str,
    status: str,
    created_by: User,
    updated_by: User,
    created_at: datetime,
    updated_at: datetime,
    steps: list[dict],
) -> Sop:
    sop = db.scalar(select(Sop).where(Sop.space_id == space.id, Sop.slug == slug))
    if not sop:
        sop = Sop(
            id=seed_uuid("sop", space.slug, slug),
            space_id=space.id,
            folder_id=folder.id if folder else None,
            slug=slug,
            title=title,
            overview_md=overview_md,
            status=status,
            created_by=created_by.id,
            updated_by=updated_by.id,
            created_at=created_at,
            updated_at=updated_at,
        )
        db.add(sop)

    sop.space_id = space.id
    sop.folder_id = folder.id if folder else None
    sop.slug = slug
    sop.title = title
    sop.overview_md = overview_md
    sop.status = status
    sop.created_by = created_by.id
    sop.updated_by = updated_by.id
    sop.created_at = created_at
    sop.updated_at = updated_at

    # Persist SOP before step replacement/insert.
    db.flush()

    desired_step_ids: set[str] = set()
    for step in steps:
        step_id = seed_uuid("sop-step", space.slug, slug, str(step["step_order"]))
        desired_step_ids.add(step_id)
        upsert_row(
            db,
            SopStep,
            pk_field="id",
            pk_value=step_id,
            sop_id=sop.id,
            step_order=step["step_order"],
            title=step["title"],
            body_md=step["body_md"],
        )

    existing_step_ids = list(
        db.execute(select(SopStep.id).where(SopStep.sop_id == sop.id)).scalars().all()
    )
    obsolete_step_ids = [
        step_id for step_id in existing_step_ids if step_id not in desired_step_ids
    ]
    if obsolete_step_ids:
        db.execute(
            delete(SopStepMeta).where(SopStepMeta.step_id.in_(obsolete_step_ids))
        )
        db.execute(
            delete(SopStepEvidenceRule).where(
                SopStepEvidenceRule.step_id.in_(obsolete_step_ids)
            )
        )
        db.execute(delete(SopStep).where(SopStep.id.in_(obsolete_step_ids)))
    db.flush()
    return sop


def get_or_create_incident(
    db: Session,
    *,
    key: str,
    space: Space,
    folder: Folder | None = None,
    title: str,
    status: str,
    severity: int,
    summary_md: str,
    created_by: User,
    created_at: datetime,
    timeline: list[dict],
) -> Incident:
    incident_id = seed_uuid("incident", space.slug, key)
    incident = db.get(Incident, incident_id)
    if not incident:
        incident = Incident(
            id=incident_id,
            space_id=space.id,
            folder_id=folder.id if folder else None,
            title=title,
            status=status,
            severity=severity,
            summary_md=summary_md,
            created_by=created_by.id,
            created_at=created_at,
        )
        db.add(incident)

    incident.space_id = space.id
    incident.folder_id = folder.id if folder else None
    incident.title = title
    incident.status = status
    incident.severity = severity
    incident.summary_md = summary_md
    incident.created_by = created_by.id
    incident.created_at = created_at

    # Persist incident before timeline replacement/insert.
    db.flush()

    desired_timeline_ids: set[str] = set()
    for idx, entry in enumerate(timeline, start=1):
        timeline_id = seed_uuid("incident-timeline", space.slug, key, str(idx))
        desired_timeline_ids.add(timeline_id)
        upsert_row(
            db,
            IncidentTimeline,
            pk_field="id",
            pk_value=timeline_id,
            incident_id=incident.id,
            ts=entry["ts"],
            entry_md=entry["entry_md"],
            created_by=entry["created_by"].id,
        )

    existing_timeline_ids = list(
        db.execute(
            select(IncidentTimeline.id).where(
                IncidentTimeline.incident_id == incident.id
            )
        )
        .scalars()
        .all()
    )
    obsolete_timeline_ids = [
        timeline_id
        for timeline_id in existing_timeline_ids
        if timeline_id not in desired_timeline_ids
    ]
    if obsolete_timeline_ids:
        db.execute(
            delete(IncidentTimelineMeta).where(
                IncidentTimelineMeta.timeline_id.in_(obsolete_timeline_ids)
            )
        )
        db.execute(
            delete(IncidentTimeline).where(
                IncidentTimeline.id.in_(obsolete_timeline_ids)
            )
        )
    db.flush()
    return incident


def upsert_event(
    db: Session,
    *,
    event_id: str,
    ts_value: datetime,
    session_id: str,
    event_type: str,
    user: User | None,
    space: Space | None,
    entity_type: str | None,
    entity_id: str | None,
    path: str | None,
    meta: dict[str, Any],
) -> Event:
    event = db.get(Event, event_id)
    if not event:
        event = Event(id=event_id)
        db.add(event)

    event.ts = ts_value
    event.user_id = user.id if user else None
    event.session_id = session_id
    event.event_type = event_type
    event.space_id = space.id if space else None
    event.entity_type = entity_type
    event.entity_id = entity_id
    event.path = path
    event.meta_json = json.dumps(meta, ensure_ascii=False)
    return event


def upsert_row(
    db: Session,
    row_model: type[Any],
    *,
    pk_field: str,
    pk_value: Any,
    **fields: Any,
) -> Any:
    row = db.get(row_model, pk_value)
    if not row:
        row = row_model(**{pk_field: pk_value})
        db.add(row)
    for key, value in fields.items():
        setattr(row, key, value)
    return row


def get_or_create_custom_role(
    db: Session,
    *,
    role_key: str,
    name: str,
    description: str,
    effective_level: str,
    active: bool,
    meta: dict[str, Any] | None = None,
) -> CustomRole:
    row = db.scalar(select(CustomRole).where(CustomRole.role_key == role_key))
    if not row:
        row = CustomRole(id=seed_uuid("custom-role", role_key), role_key=role_key)
        db.add(row)
    row.name = name
    row.description = description
    row.effective_level = effective_level
    row.active = active
    row.meta_json = json.dumps(
        meta if meta is not None else {"seeded": True, "role_key": role_key},
        ensure_ascii=False,
        separators=(",", ":"),
    )
    return row


def get_or_create_org_unit(
    db: Session,
    *,
    slug: str,
    name: str,
    unit_type: str,
    parent: OrganizationUnit | None,
    active: bool,
    created_at: datetime,
    updated_at: datetime,
    meta: dict[str, Any] | None = None,
) -> OrganizationUnit:
    row = db.scalar(select(OrganizationUnit).where(OrganizationUnit.slug == slug))
    if not row:
        row = OrganizationUnit(id=seed_uuid("org-unit", slug), slug=slug)
        db.add(row)
    row.name = name
    row.slug = slug
    row.unit_type = unit_type
    row.active = active
    row.meta_json = json.dumps(
        meta if meta is not None else {"seeded": True, "unit_type": unit_type},
        ensure_ascii=False,
        separators=(",", ":"),
    )
    row.created_at = created_at
    row.updated_at = updated_at
    db.flush()
    next_parent_id = parent.id if parent else None
    parent_links = list(
        db.execute(
            select(OrganizationItemLink).where(
                OrganizationItemLink.parent_kind == "department",
                OrganizationItemLink.child_kind == "department",
                OrganizationItemLink.child_id == row.id,
            )
        )
        .scalars()
        .all()
    )
    for link in parent_links:
        if next_parent_id is not None and link.parent_id == next_parent_id:
            continue
        db.delete(link)
    if next_parent_id is not None:
        upsert_org_item_link(
            db,
            parent_kind="department",
            parent_id=next_parent_id,
            child_kind="department",
            child_id=row.id,
            grant_role="member",
            inherit_to_descendants=True,
            active=True,
        )
    return row


def ensure_media_blob(storage_key: str, content: bytes) -> None:
    file_path = Path(settings.media_storage_dir).resolve() / storage_key
    file_path.parent.mkdir(parents=True, exist_ok=True)
    file_path.write_bytes(content)


def upsert_media_asset(
    db: Session,
    *,
    asset_id: str,
    owner: User,
    space: Space | None,
    usage: str,
    original_filename: str,
    content_type: str,
    storage_key: str,
    content: bytes,
    size_bytes: int | None = None,
    created_at: datetime,
) -> MediaAsset:
    ensure_media_blob(storage_key, content)
    row = upsert_row(
        db,
        MediaAsset,
        pk_field="id",
        pk_value=asset_id,
        owner_user_id=owner.id,
        space_id=space.id if space else None,
        usage=usage,
        original_filename=original_filename,
        content_type=content_type,
        size_bytes=len(content) if size_bytes is None else size_bytes,
        storage_key=storage_key,
        created_at=created_at,
    )
    return row


def sop_steps_by_order(db: Session, sop: Sop) -> dict[int, SopStep]:
    rows = (
        db.execute(
            select(SopStep)
            .where(SopStep.sop_id == sop.id)
            .order_by(SopStep.step_order.asc())
        )
        .scalars()
        .all()
    )
    return {int(step.step_order): step for step in rows}


def incident_timeline_rows(db: Session, incident: Incident) -> list[IncidentTimeline]:
    return list(
        db.execute(
            select(IncidentTimeline)
            .where(IncidentTimeline.incident_id == incident.id)
            .order_by(IncidentTimeline.ts.asc(), IncidentTimeline.id.asc())
        )
        .scalars()
        .all()
    )


def md(lines: list[str]) -> str:
    return "\n".join(lines).strip() + "\n"


def seed_users(db: Session) -> dict[str, User]:
    user_specs = {
        "admin": ("admin@admin.com", "Admin", "admin"),
        "moderator": ("moderator@moderator.com", "Moderator", "moderator"),
        "member": ("member@member.com", "Member", "member"),
        "viewer": ("viewer@viewer.com", "Viewer", "viewer"),
        "platform_lead": ("alex.chen@opsatlas.com", "Alex Chen", "member"),
        "retail_director": ("maria.garcia@opsatlas.com", "Maria Garcia", "member"),
        "support_qa": ("nina.patel@opsatlas.com", "Nina Patel", "member"),
        "ops_analyst": ("samir.khan@opsatlas.com", "Samir Khan", "member"),
        "compliance": ("jordan.lee@opsatlas.com", "Jordan Lee", "viewer"),
        "west_region_manager": (
            "lena.vogel@opsatlas.com",
            "Lena Vogel",
            "member",
        ),
        "east_region_manager": (
            "jonas.weber@opsatlas.com",
            "Jonas Weber",
            "member",
        ),
        "eu_region_manager": (
            "chris.morgan@opsatlas.com",
            "Chris Morgan",
            "member",
        ),
        "seattle_store_manager": (
            "jamie.nguyen@opsatlas.com",
            "Jamie Nguyen",
            "member",
        ),
        "atlanta_store_manager": (
            "oliver.brooks@opsatlas.com",
            "Oliver Brooks",
            "member",
        ),
        "berlin_store_manager": (
            "emma.schmidt@opsatlas.com",
            "Emma Schmidt",
            "member",
        ),
        "berlin_store2_manager": (
            "max.hoffmann@opsatlas.com",
            "Max Hoffmann",
            "member",
        ),
        "berlin_store3_manager": (
            "sara.keller@opsatlas.com",
            "Sara Keller",
            "member",
        ),
        "munich_store_manager": (
            "lukas.bauer@opsatlas.com",
            "Lukas Bauer",
            "member",
        ),
        "hamburg_store_manager": (
            "milan.krause@opsatlas.com",
            "Milan Krause",
            "member",
        ),
        "paris_store_manager": (
            "claire.dubois@opsatlas.com",
            "Claire Dubois",
            "member",
        ),
        "austin_store_manager": (
            "ethan.harris@opsatlas.com",
            "Ethan Harris",
            "member",
        ),
        "ops_command_manager": (
            "sofia.ivanova@opsatlas.com",
            "Sofia Ivanova",
            "member",
        ),
        "merchandising_manager": (
            "priya.desai@opsatlas.com",
            "Priya Desai",
            "member",
        ),
        "store_analyst": ("liam.murphy@opsatlas.com", "Liam Murphy", "viewer"),
    }

    first_names = [
        "Adrian",
        "Amelia",
        "Arda",
        "Aylin",
        "Bora",
        "Celine",
        "Damian",
        "Elif",
        "Emre",
        "Farah",
        "Felix",
        "Hana",
        "Ipek",
        "Jon",
        "Kaan",
        "Lara",
        "Leo",
        "Maya",
        "Mert",
        "Nora",
        "Omar",
        "Pelin",
        "Quinn",
        "Rina",
        "Sude",
        "Theo",
        "Umut",
        "Vera",
        "Yasmin",
        "Zara",
    ]
    last_names = [
        "Aydin",
        "Bennett",
        "Carver",
        "Demir",
        "Ersoy",
        "Fischer",
        "Guler",
        "Hale",
        "Inan",
        "Jansen",
        "Kaya",
        "Larson",
        "Meyer",
        "Narin",
        "Ortega",
        "Petrov",
        "Quintana",
        "Rossi",
        "Sahin",
        "Turner",
        "Ulusoy",
        "Valdez",
        "Weiss",
        "Xu",
        "Yildiz",
        "Zimmer",
    ]
    used_names = {spec[1] for spec in user_specs.values()}
    name_index = 0

    def next_generated_name() -> str:
        nonlocal name_index
        while True:
            first = first_names[name_index % len(first_names)]
            last = last_names[(name_index // len(first_names)) % len(last_names)]
            name_index += 1
            candidate = f"{first} {last}"
            if candidate not in used_names:
                used_names.add(candidate)
                return candidate

    store_aliases = [
        ("berlin_mitte", "berlin.mitte"),
        ("berlin_kudamm", "berlin.kudamm"),
        ("berlin_eastside", "berlin.eastside"),
        ("munich_marienplatz", "munich.marienplatz"),
        ("hamburg_jungfernstieg", "hamburg.jungfernstieg"),
        ("paris_opera", "paris.opera"),
        ("austin_domain", "austin.domain"),
        ("seattle_university_village", "seattle.university.village"),
        ("atlanta_lenox", "atlanta.lenox"),
    ]
    for alias, mail_prefix in store_aliases:
        for idx in range(1, 7):
            key = f"store_{alias}_associate_{idx:02d}"
            email = f"{mail_prefix}.associate.{idx:02d}@opsatlas.com"
            global_role = "member" if idx <= 4 else "viewer"
            user_specs[key] = (email, next_generated_name(), global_role)

    region_aliases = [
        ("emea_north", "emea.north"),
        ("emea_central", "emea.central"),
        ("americas", "americas"),
    ]
    for alias, mail_prefix in region_aliases:
        for idx in range(1, 5):
            key = f"region_{alias}_coordinator_{idx:02d}"
            email = f"{mail_prefix}.coordinator.{idx:02d}@opsatlas.com"
            user_specs[key] = (email, next_generated_name(), "member")

    corp_specialists = [
        ("corp_supply_chain_specialist", "supply.chain.specialist"),
        ("corp_people_ops_specialist", "people.ops.specialist"),
        ("corp_it_service_specialist", "it.service.specialist"),
        ("corp_training_specialist", "training.specialist"),
        ("corp_finance_ops_specialist", "finance.ops.specialist"),
        ("corp_visual_merch_specialist", "visual.merch.specialist"),
        ("corp_facilities_specialist", "facilities.specialist"),
        ("corp_security_specialist", "security.specialist"),
        ("corp_quality_specialist", "quality.specialist"),
        ("corp_field_engineering_specialist", "field.engineering.specialist"),
    ]
    for key, mail_prefix in corp_specialists:
        email = f"{mail_prefix}@opsatlas.com"
        user_specs[key] = (email, next_generated_name(), "member")

    if len(user_specs) != 100:
        raise RuntimeError(
            f"Seed user spec mismatch: expected 100 users, got {len(user_specs)}"
        )

    def user_meta(key: str, email: str) -> dict[str, Any]:
        employee_code = key.upper().replace("_", "-")
        return {
            "employee_code": employee_code,
            "employment_document_url": f"/media/dummy/employment/{employee_code.lower()}.pdf",
            "cost_center": "operations",
            "directory_source": "dummy-seed",
            "directory_tenant": "opsatlas",
            "contact_email": email,
        }

    users = {
        key: get_or_create_user(
            db,
            email=email,
            name=name,
            global_role=global_role,
            password="password",
            meta=user_meta(key, email),
        )
        for key, (email, name, global_role) in user_specs.items()
    }

    # Persist users before any rows that reference them.
    db.flush()
    return users


def seed_platform_ops(
    db: Session, users: dict[str, User], refs: dict[str, dict[str, Any]]
) -> None:
    space = get_or_create_space(
        db,
        slug="platform-ops",
        name="OpsAtlas Companywide Operations",
        created_at=ts(days_ago=120),
        region_code="GLOBAL",
        meta={
            "scope": "companywide",
            "domain": "operations",
            "space_category": "company-hub",
            "seeded_for": "item-first",
        },
    )
    refs["spaces"]["platform-ops"] = space

    upsert_space_member(db, space_id=space.id, user_id=users["admin"].id, role="admin")
    upsert_space_member(
        db, space_id=space.id, user_id=users["moderator"].id, role="moderator"
    )
    upsert_space_member(
        db, space_id=space.id, user_id=users["member"].id, role="member"
    )
    upsert_space_member(
        db, space_id=space.id, user_id=users["viewer"].id, role="viewer"
    )

    runbooks = get_or_create_folder(db, space=space, name="Runbooks", parent=None)
    deployments = get_or_create_folder(
        db, space=space, name="Deployments", parent=runbooks
    )
    databases = get_or_create_folder(db, space=space, name="Databases", parent=runbooks)
    architecture = get_or_create_folder(
        db, space=space, name="Architecture", parent=None
    )
    onboarding = get_or_create_folder(db, space=space, name="Onboarding", parent=None)
    refs["folders"].update(
        {
            "platform-ops:runbooks": runbooks,
            "platform-ops:deployments": deployments,
            "platform-ops:databases": databases,
            "platform-ops:architecture": architecture,
            "platform-ops:onboarding": onboarding,
        }
    )

    d = get_or_create_doc
    refs["docs"]["platform-ops:incident-commander-quickstart"] = d(
        db,
        space=space,
        slug="incident-commander-quickstart",
        title="Incident Commander Quickstart",
        folder=runbooks,
        created_by=users["admin"],
        updated_by=users["moderator"],
        status="published",
        created_at=ts(days_ago=90),
        updated_at=ts(days_ago=3, hours=2),
        published_at=ts(days_ago=89),
        content_md=md(
            [
                "# Incident Commander Quickstart",
                "",
                "Use this checklist for any Sev-1 or Sev-2 production incident.",
                "",
                "## First 10 Minutes",
                "- Assign incident commander and scribe.",
                "- Open a dedicated Slack channel and video bridge.",
                "- State impact, scope, and current mitigation status.",
                "- Freeze unrelated production changes until stabilized.",
                "",
                "## Communication Cadence",
                "- Sev-1: updates every 15 minutes",
                "- Sev-2: updates every 30 minutes",
                "",
                "## Exit Criteria",
                "- Customer impact removed",
                "- Monitoring stable for two consecutive checks",
                "- Follow-up owner assigned for postmortem",
            ]
        ),
        versions=[
            {
                "title": "Incident Commander Quickstart",
                "content_md": md(
                    [
                        "# Incident Commander Quickstart",
                        "",
                        "Initial version used for drills.",
                        "",
                        "- Assign commander",
                        "- Create channel",
                        "- Publish status update",
                    ]
                ),
                "created_by": users["admin"],
                "created_at": ts(days_ago=90),
            },
            {
                "title": "Incident Commander Quickstart",
                "content_md": md(
                    [
                        "# Incident Commander Quickstart",
                        "",
                        "Expanded with communication cadence and exit criteria.",
                        "",
                        "- Assign commander and scribe",
                        "- Open channel + bridge",
                        "- Publish status updates on fixed cadence",
                        "- Assign postmortem owner",
                    ]
                ),
                "created_by": users["moderator"],
                "created_at": ts(days_ago=3, hours=2),
            },
        ],
    )

    refs["docs"]["platform-ops:api-release-checklist"] = d(
        db,
        space=space,
        slug="api-release-checklist",
        title="API Release Checklist",
        folder=deployments,
        created_by=users["admin"],
        updated_by=users["member"],
        status="published",
        created_at=ts(days_ago=70),
        updated_at=ts(days_ago=1, hours=6),
        published_at=ts(days_ago=69),
        content_md=md(
            [
                "# API Release Checklist",
                "",
                "Release checklist for the FastAPI monolith.",
                "",
                "## Before Merge",
                "- CI green on backend + Flutter web smoke test",
                "- DB migration reviewed and rollback plan documented",
                "- Feature flags defaulted to safe values",
                "",
                "## Before Deploy",
                "- Confirm on-call engineer is available",
                "- Confirm error budget status for the week",
                "- Post release notice in `#ops-release`",
                "",
                "## After Deploy",
                "- Check `/health` and auth login flow",
                "- Watch p95 latency and 5xx for 15 minutes",
                "- Close release thread with metrics summary",
            ]
        ),
        versions=[
            {
                "title": "API Release Checklist",
                "content_md": md(
                    [
                        "# API Release Checklist",
                        "",
                        "- Confirm CI green",
                        "- Deploy",
                        "- Check health endpoint",
                    ]
                ),
                "created_by": users["admin"],
                "created_at": ts(days_ago=70),
            },
            {
                "title": "API Release Checklist",
                "content_md": md(
                    [
                        "# API Release Checklist",
                        "",
                        "Added pre-merge and post-deploy observability checks.",
                        "",
                        "- CI green",
                        "- Migration rollback plan",
                        "- Post deploy metric watch",
                    ]
                ),
                "created_by": users["member"],
                "created_at": ts(days_ago=1, hours=6),
            },
        ],
    )

    refs["docs"]["platform-ops:postgres-restore-drill"] = d(
        db,
        space=space,
        slug="postgres-restore-drill",
        title="Postgres Restore Drill Notes",
        folder=databases,
        created_by=users["moderator"],
        updated_by=users["moderator"],
        status="draft",
        created_at=ts(days_ago=30),
        updated_at=ts(days_ago=2, hours=4),
        published_at=None,
        content_md=md(
            [
                "# Postgres Restore Drill Notes",
                "",
                "Draft run notes from the monthly restore exercise against staging data.",
                "",
                "## Goal",
                "Validate recovery point objective under 15 minutes for `OpsAtlas`.",
                "",
                "## Findings",
                "- Base backup download completed in 4m 20s over LAN.",
                "- WAL replay added 6m 45s.",
                "- App came back healthy after cache flush and one worker restart.",
                "",
                "## Follow-ups",
                "- Automate verification query set after restore.",
                "- Snapshot `pg_hba.conf` with backups to reduce manual steps.",
            ]
        ),
        versions=[
            {
                "title": "Postgres Restore Drill Notes",
                "content_md": md(
                    [
                        "# Postgres Restore Drill Notes",
                        "",
                        "Initial draft from drill.",
                        "",
                    ]
                ),
                "created_by": users["moderator"],
                "created_at": ts(days_ago=30),
            },
            {
                "title": "Postgres Restore Drill Notes",
                "content_md": md(
                    [
                        "# Postgres Restore Drill Notes",
                        "",
                        "Expanded timing and follow-up actions after review.",
                    ]
                ),
                "created_by": users["moderator"],
                "created_at": ts(days_ago=2, hours=4),
            },
        ],
    )

    refs["docs"]["platform-ops:service-dependency-map"] = d(
        db,
        space=space,
        slug="service-dependency-map",
        title="Service Dependency Map",
        folder=architecture,
        created_by=users["admin"],
        updated_by=users["admin"],
        status="published",
        created_at=ts(days_ago=100),
        updated_at=ts(days_ago=10),
        published_at=ts(days_ago=99),
        content_md=md(
            [
                "# Service Dependency Map",
                "",
                "## Critical Path",
                "Flutter Web -> FastAPI API -> Postgres",
                "",
                "## Supporting Services",
                "- Backup Service (snapshot browsing demo)",
                "- Browser-based admin tooling",
                "",
                "## Operational Notes",
                "- Auth and spaces endpoints are required for almost all UI routes.",
                "- Backup browsing can fail independently without blocking core workflows.",
            ]
        ),
        versions=[
            {
                "title": "Service Dependency Map",
                "content_md": md(
                    ["# Service Dependency Map", "", "Initial architecture sketch."]
                ),
                "created_by": users["admin"],
                "created_at": ts(days_ago=100),
            }
        ],
    )

    refs["docs"]["platform-ops:new-engineer-week-1"] = d(
        db,
        space=space,
        slug="new-engineer-week-1",
        title="New Engineer Onboarding: Week 1",
        folder=onboarding,
        created_by=users["admin"],
        updated_by=users["member"],
        status="published",
        created_at=ts(days_ago=45),
        updated_at=ts(days_ago=8),
        published_at=ts(days_ago=44),
        content_md=md(
            [
                "# New Engineer Onboarding: Week 1",
                "",
                "## Day 1",
                "- Access: GitHub, CI, production read-only dashboards",
                "- Pair on login -> spaces -> admin/backups smoke test",
                "",
                "## Day 2-3",
                "- Read release checklist and incident commander quickstart",
                "- Shadow one deploy in staging",
                "",
                "## Day 4-5",
                "- Run a guided rollback drill",
                "- Submit one doc improvement PR",
            ]
        ),
        versions=[
            {
                "title": "New Engineer Onboarding: Week 1",
                "content_md": md(
                    [
                        "# New Engineer Onboarding: Week 1",
                        "",
                        "Draft onboarding outline.",
                    ]
                ),
                "created_by": users["admin"],
                "created_at": ts(days_ago=45),
            },
            {
                "title": "New Engineer Onboarding: Week 1",
                "content_md": md(
                    [
                        "# New Engineer Onboarding: Week 1",
                        "",
                        "Added drill and documentation tasks.",
                    ]
                ),
                "created_by": users["member"],
                "created_at": ts(days_ago=8),
            },
        ],
    )

    refs["sops"]["platform-ops:rollback-api-release"] = get_or_create_sop(
        db,
        space=space,
        slug="rollback-api-release",
        title="Rollback API Release",
        overview_md=md(
            [
                "# Rollback API Release",
                "",
                "Used when a production deployment introduces sustained 5xx errors or severe latency regression.",
            ]
        ),
        status="published",
        created_by=users["admin"],
        updated_by=users["moderator"],
        created_at=ts(days_ago=80),
        updated_at=ts(days_ago=5, hours=3),
        steps=[
            {
                "step_order": 1,
                "title": "Confirm rollback criteria",
                "body_md": "Check error rate, p95 latency, and user impact.",
            },
            {
                "step_order": 2,
                "title": "Pause further deployments",
                "body_md": "Freeze the release queue and notify the release channel.",
            },
            {
                "step_order": 3,
                "title": "Deploy previous artifact",
                "body_md": "Use the last known good image tag in production deploy workflow.",
            },
            {
                "step_order": 4,
                "title": "Run smoke tests",
                "body_md": "Validate `/health`, auth login, and spaces list.",
            },
            {
                "step_order": 5,
                "title": "Monitor stabilization",
                "body_md": "Watch 5xx, latency, DB pool saturation for 15 minutes.",
            },
            {
                "step_order": 6,
                "title": "Document incident context",
                "body_md": "Open or update incident with rollback reason and follow-ups.",
            },
        ],
    )

    refs["sops"]["platform-ops:rotate-db-credentials"] = get_or_create_sop(
        db,
        space=space,
        slug="rotate-db-credentials",
        title="Rotate Database Credentials",
        overview_md=md(
            [
                "# Rotate Database Credentials",
                "",
                "Quarterly credential rotation for app database users and automation service accounts.",
            ]
        ),
        status="draft",
        created_by=users["moderator"],
        updated_by=users["moderator"],
        created_at=ts(days_ago=40),
        updated_at=ts(days_ago=4, hours=1),
        steps=[
            {
                "step_order": 1,
                "title": "Create new DB credentials",
                "body_md": "Generate a new password in the team vault and create DB user or alter password.",
            },
            {
                "step_order": 2,
                "title": "Update application secret",
                "body_md": "Rotate secret in deployment environment without removing previous access yet.",
            },
            {
                "step_order": 3,
                "title": "Restart application workers",
                "body_md": "Roll restart to ensure all processes pick up the new secret.",
            },
            {
                "step_order": 4,
                "title": "Validate database connectivity",
                "body_md": "Run login flow and create a test record in staging/admin workflow.",
            },
            {
                "step_order": 5,
                "title": "Revoke previous credentials",
                "body_md": "Disable old credentials after successful verification window.",
            },
        ],
    )

    refs["incidents"]["platform-ops:latency-spike-after-release"] = (
        get_or_create_incident(
            db,
            key="latency-spike-after-release",
            space=space,
            title="API latency spike after release 2026.02.24",
            status="resolved",
            severity=2,
            summary_md=md(
                [
                    "# Summary",
                    "",
                    "After a production API release, p95 latency increased from ~180ms to ~1.8s.",
                    "Rollback restored baseline metrics. Root cause was an unbounded query path in analytics aggregation.",
                    "",
                    "## Impact",
                    "- Intermittent slow page loads in admin and spaces screens",
                    "- Elevated timeout rate for login and backup proxy calls",
                ]
            ),
            created_by=users["admin"],
            created_at=ts(days_ago=2, hours=10),
            timeline=[
                {
                    "ts": ts(days_ago=2, hours=10),
                    "entry_md": "Alert fired for API p95 > 1500ms for 5 minutes.",
                    "created_by": users["viewer"],
                },
                {
                    "ts": ts(days_ago=2, hours=9, minutes=52),
                    "entry_md": "Incident channel created. Release frozen pending triage.",
                    "created_by": users["moderator"],
                },
                {
                    "ts": ts(days_ago=2, hours=9, minutes=40),
                    "entry_md": "Latency linked to new analytics endpoint query path; DB CPU spiking.",
                    "created_by": users["member"],
                },
                {
                    "ts": ts(days_ago=2, hours=9, minutes=28),
                    "entry_md": "Rollback completed to previous image; latency trending down.",
                    "created_by": users["admin"],
                },
                {
                    "ts": ts(days_ago=2, hours=9, minutes=5),
                    "entry_md": "Resolved after 20-minute monitoring window. Follow-up ticket opened for query limit.",
                    "created_by": users["moderator"],
                },
            ],
        )
    )

    refs["incidents"]["platform-ops:backup-proxy-timeouts"] = get_or_create_incident(
        db,
        key="backup-proxy-timeouts",
        space=space,
        title="Backup proxy timeouts during snapshot browsing",
        status="monitoring",
        severity=3,
        summary_md=md(
            [
                "# Summary",
                "",
                "Admins observed timeout errors while browsing large snapshot trees.",
                "Issue appears limited to the backup proxy path and does not affect auth or core spaces endpoints.",
                "",
                "## Current Mitigation",
                "- Increased client timeout in the browser build used by QA",
                "- Tracking tree sizes and response times from demo backup service",
            ]
        ),
        created_by=users["moderator"],
        created_at=ts(days_ago=1, hours=6),
        timeline=[
            {
                "ts": ts(days_ago=1, hours=6),
                "entry_md": "QA reported intermittent timeout on `/admin/backups/snapshots/{id}/tree`.",
                "created_by": users["viewer"],
            },
            {
                "ts": ts(days_ago=1, hours=5, minutes=45),
                "entry_md": "Scoped to backup browsing endpoints; main app remains healthy.",
                "created_by": users["moderator"],
            },
            {
                "ts": ts(days_ago=1, hours=5, minutes=10),
                "entry_md": "Temporary mitigation documented; monitoring during test sessions.",
                "created_by": users["admin"],
            },
        ],
    )


def seed_store_ops(
    db: Session, users: dict[str, User], refs: dict[str, dict[str, Any]]
) -> None:
    space = get_or_create_space(
        db,
        slug="store-ops",
        name="Store Operations",
        created_at=ts(days_ago=150),
        region_code="US",
        meta={"scope": "regional", "domain": "retail"},
    )
    refs["spaces"]["store-ops"] = space

    upsert_space_member(db, space_id=space.id, user_id=users["admin"].id, role="admin")
    upsert_space_member(
        db, space_id=space.id, user_id=users["moderator"].id, role="admin"
    )
    upsert_space_member(
        db, space_id=space.id, user_id=users["member"].id, role="moderator"
    )
    upsert_space_member(
        db, space_id=space.id, user_id=users["viewer"].id, role="viewer"
    )

    operations = get_or_create_folder(db, space=space, name="Operations", parent=None)
    opening = get_or_create_folder(db, space=space, name="Opening", parent=operations)
    closing = get_or_create_folder(db, space=space, name="Closing", parent=operations)
    hardware = get_or_create_folder(db, space=space, name="Hardware", parent=None)
    inventory = get_or_create_folder(db, space=space, name="Inventory", parent=None)
    refs["folders"].update(
        {
            "store-ops:operations": operations,
            "store-ops:opening": opening,
            "store-ops:closing": closing,
            "store-ops:hardware": hardware,
            "store-ops:inventory": inventory,
        }
    )

    d = get_or_create_doc
    refs["docs"]["store-ops:store-opening-checklist"] = d(
        db,
        space=space,
        slug="store-opening-checklist",
        title="Store Opening Checklist",
        folder=opening,
        created_by=users["member"],
        updated_by=users["moderator"],
        status="published",
        created_at=ts(days_ago=110),
        updated_at=ts(days_ago=6),
        published_at=ts(days_ago=109),
        content_md=md(
            [
                "# Store Opening Checklist",
                "",
                "Daily opening routine for physical retail locations.",
                "",
                "- Disarm alarm and confirm overnight incident log",
                "- Power on POS terminals and verify network sync",
                "- Count opening cash float and record variance",
                "- Print first test receipt from each active terminal",
                "- Check curbside pickup queue board",
            ]
        ),
        versions=[
            {
                "title": "Store Opening Checklist",
                "content_md": md(
                    ["# Store Opening Checklist", "", "Initial opening steps."]
                ),
                "created_by": users["member"],
                "created_at": ts(days_ago=110),
            },
            {
                "title": "Store Opening Checklist",
                "content_md": md(
                    [
                        "# Store Opening Checklist",
                        "",
                        "Added curbside pickup board check.",
                    ]
                ),
                "created_by": users["moderator"],
                "created_at": ts(days_ago=6),
            },
        ],
    )

    refs["docs"]["store-ops:store-closing-cash-drop"] = d(
        db,
        space=space,
        slug="store-closing-cash-drop",
        title="Store Closing and Cash Drop",
        folder=closing,
        created_by=users["moderator"],
        updated_by=users["moderator"],
        status="published",
        created_at=ts(days_ago=105),
        updated_at=ts(days_ago=12),
        published_at=ts(days_ago=104),
        content_md=md(
            [
                "# Store Closing and Cash Drop",
                "",
                "Procedure for end-of-day close and secure cash drop.",
                "",
                "## Close Sequence",
                "1. Reconcile POS sales totals with drawer counts",
                "2. Bag deposit with store/date label",
                "3. Lock safe and verify alarm panel status",
                "4. Submit close report before leaving site",
            ]
        ),
        versions=[
            {
                "title": "Store Closing and Cash Drop",
                "content_md": md(
                    ["# Store Closing and Cash Drop", "", "Baseline close procedure."]
                ),
                "created_by": users["moderator"],
                "created_at": ts(days_ago=105),
            }
        ],
    )

    refs["docs"]["store-ops:pos-terminal-health-check"] = d(
        db,
        space=space,
        slug="pos-terminal-health-check",
        title="POS Terminal Daily Health Check",
        folder=hardware,
        created_by=users["member"],
        updated_by=users["member"],
        status="published",
        created_at=ts(days_ago=80),
        updated_at=ts(days_ago=1, hours=2),
        published_at=ts(days_ago=79),
        content_md=md(
            [
                "# POS Terminal Daily Health Check",
                "",
                "Perform before peak traffic windows to avoid front-line delays.",
                "",
                "- Check printer paper and print head status",
                "- Run card reader test transaction in training mode",
                "- Confirm terminal clock sync within 1 minute",
                "- Validate inventory sync timestamp < 10 minutes old",
            ]
        ),
        versions=[
            {
                "title": "POS Terminal Daily Health Check",
                "content_md": md(
                    [
                        "# POS Terminal Daily Health Check",
                        "",
                        "Initial hardware validation checklist.",
                    ]
                ),
                "created_by": users["member"],
                "created_at": ts(days_ago=80),
            },
            {
                "title": "POS Terminal Daily Health Check",
                "content_md": md(
                    [
                        "# POS Terminal Daily Health Check",
                        "",
                        "Added inventory sync timestamp validation.",
                    ]
                ),
                "created_by": users["member"],
                "created_at": ts(days_ago=1, hours=2),
            },
        ],
    )

    refs["docs"]["store-ops:cycle-count-escalation-guide"] = d(
        db,
        space=space,
        slug="cycle-count-escalation-guide",
        title="Cycle Count Escalation Guide",
        folder=inventory,
        created_by=users["moderator"],
        updated_by=users["moderator"],
        status="draft",
        created_at=ts(days_ago=25),
        updated_at=ts(days_ago=3, hours=8),
        published_at=None,
        content_md=md(
            [
                "# Cycle Count Escalation Guide",
                "",
                "Draft guidance for escalating inventory discrepancies discovered during cycle counts.",
                "",
                "Escalate immediately when discrepancy exceeds:",
                "- 5 units for controlled accessories",
                "- 1 unit for serialized electronics",
                "- Any variance involving returned items marked as resellable",
            ]
        ),
        versions=[
            {
                "title": "Cycle Count Escalation Guide",
                "content_md": md(
                    [
                        "# Cycle Count Escalation Guide",
                        "",
                        "Draft thresholds under review.",
                    ]
                ),
                "created_by": users["moderator"],
                "created_at": ts(days_ago=25),
            }
        ],
    )

    refs["sops"]["store-ops:replace-pos-receipt-printer"] = get_or_create_sop(
        db,
        space=space,
        slug="replace-pos-receipt-printer",
        title="Replace POS Receipt Printer",
        overview_md=md(
            [
                "# Replace POS Receipt Printer",
                "",
                "Swap a failed printer during business hours with minimal cashier downtime.",
            ]
        ),
        status="published",
        created_by=users["moderator"],
        updated_by=users["member"],
        created_at=ts(days_ago=75),
        updated_at=ts(days_ago=7),
        steps=[
            {
                "step_order": 1,
                "title": "Notify cashier and pause lane",
                "body_md": "Move customers to adjacent lane before disconnecting hardware.",
            },
            {
                "step_order": 2,
                "title": "Confirm terminal ID",
                "body_md": "Record lane and terminal ID for maintenance log.",
            },
            {
                "step_order": 3,
                "title": "Swap printer hardware",
                "body_md": "Disconnect power/USB, replace unit, and load paper roll.",
            },
            {
                "step_order": 4,
                "title": "Run test print",
                "body_md": "Use POS diagnostics to verify print quality and cut operation.",
            },
            {
                "step_order": 5,
                "title": "Resume lane and log replacement",
                "body_md": "Mark lane active and update hardware inventory sheet.",
            },
        ],
    )

    refs["sops"]["store-ops:inventory-recount-escalation"] = get_or_create_sop(
        db,
        space=space,
        slug="inventory-recount-escalation",
        title="Inventory Recount Escalation",
        overview_md=md(
            [
                "# Inventory Recount Escalation",
                "",
                "Procedure for repeating counts and escalating discrepancies to area manager and loss prevention.",
            ]
        ),
        status="published",
        created_by=users["moderator"],
        updated_by=users["moderator"],
        created_at=ts(days_ago=50),
        updated_at=ts(days_ago=9),
        steps=[
            {
                "step_order": 1,
                "title": "Perform second count with a different associate",
                "body_md": "Use the same SKU set and location boundaries.",
            },
            {
                "step_order": 2,
                "title": "Check recent transfers and returns",
                "body_md": "Confirm pending receiving paperwork and return disposition.",
            },
            {
                "step_order": 3,
                "title": "Capture discrepancy evidence",
                "body_md": "Photos, shelf labels, and transaction timestamps.",
            },
            {
                "step_order": 4,
                "title": "Escalate by threshold",
                "body_md": "Notify area manager and loss prevention based on item class and variance.",
            },
        ],
    )

    refs["incidents"]["store-ops:pos-sync-backlog"] = get_or_create_incident(
        db,
        key="pos-sync-backlog",
        space=space,
        title="POS sync backlog in EU region stores",
        status="open",
        severity=3,
        summary_md=md(
            [
                "# Summary",
                "",
                "Several stores reported stale inventory data on POS terminals due to regional sync backlog.",
                "Manual verification is in place for high-value items while engineering investigates.",
            ]
        ),
        created_by=users["member"],
        created_at=ts(days_ago=1, hours=12),
        timeline=[
            {
                "ts": ts(days_ago=1, hours=12),
                "entry_md": "First report from Paris store: inventory sync age > 40 minutes.",
                "created_by": users["viewer"],
            },
            {
                "ts": ts(days_ago=1, hours=11, minutes=40),
                "entry_md": "Confirmed issue across multiple EU stores; opened regional incident.",
                "created_by": users["member"],
            },
            {
                "ts": ts(days_ago=1, hours=11, minutes=5),
                "entry_md": "Store managers instructed to manually verify stock for serialized items.",
                "created_by": users["moderator"],
            },
        ],
    )


def seed_support_ops(
    db: Session, users: dict[str, User], refs: dict[str, dict[str, Any]]
) -> None:
    space = get_or_create_space(
        db,
        slug="customer-support",
        name="Customer Support",
        created_at=ts(days_ago=95),
        region_code="GLOBAL",
        meta={"scope": "company", "domain": "support"},
    )
    refs["spaces"]["customer-support"] = space

    upsert_space_member(db, space_id=space.id, user_id=users["admin"].id, role="admin")
    upsert_space_member(
        db, space_id=space.id, user_id=users["moderator"].id, role="moderator"
    )
    upsert_space_member(
        db, space_id=space.id, user_id=users["member"].id, role="member"
    )
    upsert_space_member(
        db, space_id=space.id, user_id=users["viewer"].id, role="viewer"
    )

    escalations = get_or_create_folder(db, space=space, name="Escalations", parent=None)
    billing = get_or_create_folder(db, space=space, name="Billing", parent=None)
    macros = get_or_create_folder(db, space=space, name="Macros", parent=None)
    qa = get_or_create_folder(db, space=space, name="Quality Reviews", parent=None)

    refs["folders"].update(
        {
            "customer-support:escalations": escalations,
            "customer-support:billing": billing,
            "customer-support:macros": macros,
            "customer-support:qa": qa,
        }
    )

    d = get_or_create_doc
    refs["docs"]["customer-support:tier1-escalation-routing"] = d(
        db,
        space=space,
        slug="tier1-escalation-routing",
        title="Tier-1 Escalation Routing",
        folder=escalations,
        created_by=users["moderator"],
        updated_by=users["moderator"],
        status="published",
        created_at=ts(days_ago=60),
        updated_at=ts(days_ago=4),
        published_at=ts(days_ago=59),
        content_md=md(
            [
                "# Tier-1 Escalation Routing",
                "",
                "Routing guide for support agents escalating issues from first response.",
                "",
                "## Route to Platform Ops",
                "- Login failures affecting multiple users",
                "- Timeouts across admin/backups or spaces pages",
                "",
                "## Route to Billing",
                "- Duplicate charges",
                "- Refund status mismatch after 24h",
                "",
                "## Route to Store Ops",
                "- POS synchronization discrepancies",
                "- Receipt printer / terminal hardware failures",
            ]
        ),
        versions=[
            {
                "title": "Tier-1 Escalation Routing",
                "content_md": md(
                    ["# Tier-1 Escalation Routing", "", "Initial routing matrix."]
                ),
                "created_by": users["moderator"],
                "created_at": ts(days_ago=60),
            }
        ],
    )

    refs["docs"]["customer-support:refund-eligibility-matrix"] = d(
        db,
        space=space,
        slug="refund-eligibility-matrix",
        title="Refund Eligibility Matrix",
        folder=billing,
        created_by=users["member"],
        updated_by=users["moderator"],
        status="published",
        created_at=ts(days_ago=55),
        updated_at=ts(days_ago=2),
        published_at=ts(days_ago=54),
        content_md=md(
            [
                "# Refund Eligibility Matrix",
                "",
                "| Scenario | Window | Approval | Notes |",
                "| --- | --- | --- | --- |",
                "| Duplicate charge | 30 days | Tier-1 | Verify processor settlement IDs |",
                "| Damaged item | 14 days | Tier-1 | Photo required for shipped orders |",
                "| Subscription renewal dispute | 7 days | Billing lead | Check cancellation timestamp |",
                "| Fraud claim | N/A | Payments team | Escalate immediately |",
            ]
        ),
        versions=[
            {
                "title": "Refund Eligibility Matrix",
                "content_md": md(
                    [
                        "# Refund Eligibility Matrix",
                        "",
                        "Original matrix with duplicate/damaged items.",
                    ]
                ),
                "created_by": users["member"],
                "created_at": ts(days_ago=55),
            },
            {
                "title": "Refund Eligibility Matrix",
                "content_md": md(
                    [
                        "# Refund Eligibility Matrix",
                        "",
                        "Added subscription renewal dispute row and processor settlement verification note.",
                    ]
                ),
                "created_by": users["moderator"],
                "created_at": ts(days_ago=2),
            },
        ],
    )

    refs["docs"]["customer-support:chat-macros-high-volume"] = d(
        db,
        space=space,
        slug="chat-macros-high-volume",
        title="Chat Macros for High-Volume Periods",
        folder=macros,
        created_by=users["member"],
        updated_by=users["member"],
        status="published",
        created_at=ts(days_ago=40),
        updated_at=ts(days_ago=1, hours=3),
        published_at=ts(days_ago=39),
        content_md=md(
            [
                "# Chat Macros for High-Volume Periods",
                "",
                "Response templates for queue spikes while preserving accurate expectations.",
                "",
                "## Delayed Refund Response",
                "> I’m checking the payment status now. Refund confirmations can take up to 3 business days after approval.",
                "",
                "## Incident Acknowledgement",
                "> We’re currently investigating a service issue affecting some users. I’ll share the next update as soon as it is posted.",
            ]
        ),
        versions=[
            {
                "title": "Chat Macros for High-Volume Periods",
                "content_md": md(
                    [
                        "# Chat Macros for High-Volume Periods",
                        "",
                        "Initial set of delay macros.",
                    ]
                ),
                "created_by": users["member"],
                "created_at": ts(days_ago=40),
            }
        ],
    )

    refs["docs"]["customer-support:qa-escalation-review-rubric"] = d(
        db,
        space=space,
        slug="qa-escalation-review-rubric",
        title="QA Escalation Review Rubric",
        folder=qa,
        created_by=users["moderator"],
        updated_by=users["viewer"],
        status="draft",
        created_at=ts(days_ago=18),
        updated_at=ts(days_ago=1),
        published_at=None,
        content_md=md(
            [
                "# QA Escalation Review Rubric",
                "",
                "Draft rubric for reviewing escalation quality during weekly coaching.",
                "",
                "Scored areas:",
                "- Correct routing",
                "- Clear reproduction details",
                "- Business impact stated",
                "- Promised follow-up time included",
            ]
        ),
        versions=[
            {
                "title": "QA Escalation Review Rubric",
                "content_md": md(
                    ["# QA Escalation Review Rubric", "", "First draft rubric."]
                ),
                "created_by": users["moderator"],
                "created_at": ts(days_ago=18),
            },
            {
                "title": "QA Escalation Review Rubric",
                "content_md": md(
                    [
                        "# QA Escalation Review Rubric",
                        "",
                        "Added business impact and follow-up time scoring items.",
                    ]
                ),
                "created_by": users["viewer"],
                "created_at": ts(days_ago=1),
            },
        ],
    )

    refs["sops"]["customer-support:after-hours-handoff"] = get_or_create_sop(
        db,
        space=space,
        folder=escalations,
        slug="after-hours-handoff",
        title="After-hours Escalation Handoff",
        overview_md=md(
            [
                "# After-hours Escalation Handoff",
                "",
                "Handoff procedure when a ticket requires another team outside standard support hours.",
            ]
        ),
        status="published",
        created_by=users["moderator"],
        updated_by=users["moderator"],
        created_at=ts(days_ago=35),
        updated_at=ts(days_ago=4),
        steps=[
            {
                "step_order": 1,
                "title": "Confirm urgency and impact",
                "body_md": "Determine whether customer-blocking or revenue-impacting.",
            },
            {
                "step_order": 2,
                "title": "Collect reproduction and account identifiers",
                "body_md": "Include exact timestamps, account ID, and observed errors.",
            },
            {
                "step_order": 3,
                "title": "Page on-call team",
                "body_md": "Use current escalation policy and include a concise incident summary.",
            },
            {
                "step_order": 4,
                "title": "Send customer acknowledgement",
                "body_md": "Provide expected update window and reference number.",
            },
            {
                "step_order": 5,
                "title": "Document handoff in ticket",
                "body_md": "Capture who was paged and when.",
            },
        ],
    )

    refs["sops"]["customer-support:refund-delay-triage"] = get_or_create_sop(
        db,
        space=space,
        folder=billing,
        slug="refund-delay-triage",
        title="Refund Delay Triage",
        overview_md=md(
            [
                "# Refund Delay Triage",
                "",
                "Structured triage for refund delays before escalation to payments or finance.",
            ]
        ),
        status="published",
        created_by=users["member"],
        updated_by=users["moderator"],
        created_at=ts(days_ago=28),
        updated_at=ts(days_ago=3),
        steps=[
            {
                "step_order": 1,
                "title": "Verify refund was approved",
                "body_md": "Check ticket notes and approval actor.",
            },
            {
                "step_order": 2,
                "title": "Check processor settlement status",
                "body_md": "Look for pending, submitted, or failed status.",
            },
            {
                "step_order": 3,
                "title": "Validate customer payment method type",
                "body_md": "Bank transfer and card refunds have different posting windows.",
            },
            {
                "step_order": 4,
                "title": "Escalate with evidence if past SLA",
                "body_md": "Include order ID, processor reference, approval timestamp.",
            },
        ],
    )

    refs["incidents"]["customer-support:refund-queue-delay"] = get_or_create_incident(
        db,
        key="refund-queue-delay",
        space=space,
        folder=billing,
        title="Refund queue delay due to payment gateway timeouts",
        status="resolved",
        severity=2,
        summary_md=md(
            [
                "# Summary",
                "",
                "Refund processing jobs accumulated after repeated timeouts from the payment gateway API.",
                "Customer notifications were delayed but no refunds were lost.",
            ]
        ),
        created_by=users["moderator"],
        created_at=ts(days_ago=5, hours=8),
        timeline=[
            {
                "ts": ts(days_ago=5, hours=8),
                "entry_md": 'Support queue reported spike in "refund pending" follow-ups.',
                "created_by": users["viewer"],
            },
            {
                "ts": ts(days_ago=5, hours=7, minutes=35),
                "entry_md": "Payments gateway timeout rate increased; retry workers lagging.",
                "created_by": users["member"],
            },
            {
                "ts": ts(days_ago=5, hours=6, minutes=50),
                "entry_md": "Retry concurrency temporarily increased; backlog draining.",
                "created_by": users["admin"],
            },
            {
                "ts": ts(days_ago=5, hours=6, minutes=5),
                "entry_md": "Queue recovered. Drafted customer response macro for delayed confirmations.",
                "created_by": users["moderator"],
            },
        ],
    )


def seed_regional_spaces(
    db: Session, users: dict[str, User], refs: dict[str, dict[str, Any]]
) -> None:
    space_specs: list[dict[str, Any]] = [
        {
            "key": "berlin-region-ops",
            "slug": "emea-north-management",
            "name": "EMEA North Management",
            "region_code": "DE-BER",
            "country_code": "DE",
            "focus": "Regional governance, staffing, and operational readiness for northern EMEA stores.",
            "created_at": ts(days_ago=128),
            "owner_user": "west_region_manager",
            "space_scope": "region",
            "space_code": "emea-north-management",
            "members": [
                ("admin", "admin"),
                ("retail_director", "admin"),
                ("west_region_manager", "admin"),
                ("berlin_store_manager", "moderator"),
                ("berlin_store2_manager", "moderator"),
                ("berlin_store3_manager", "moderator"),
                ("member", "member"),
                ("ops_analyst", "member"),
                ("viewer", "viewer"),
            ],
        },
        {
            "key": "central-europe-region-ops",
            "slug": "emea-central-management",
            "name": "EMEA Central Management",
            "region_code": "EU-CENTRAL",
            "country_code": "EU",
            "focus": "Regional planning, merchandising coordination, and readiness reviews across central EMEA.",
            "created_at": ts(days_ago=124),
            "owner_user": "east_region_manager",
            "space_scope": "region",
            "space_code": "emea-central-management",
            "members": [
                ("admin", "admin"),
                ("retail_director", "admin"),
                ("east_region_manager", "admin"),
                ("munich_store_manager", "moderator"),
                ("hamburg_store_manager", "moderator"),
                ("paris_store_manager", "moderator"),
                ("store_analyst", "member"),
                ("member", "member"),
                ("viewer", "viewer"),
            ],
        },
        {
            "key": "north-america-region-ops",
            "slug": "americas-management",
            "name": "Americas Management",
            "region_code": "NA",
            "country_code": "US",
            "focus": "Regional incident governance, staffing coverage, and launch readiness across the Americas.",
            "created_at": ts(days_ago=121),
            "owner_user": "eu_region_manager",
            "space_scope": "region",
            "space_code": "americas-management",
            "members": [
                ("admin", "admin"),
                ("retail_director", "admin"),
                ("eu_region_manager", "admin"),
                ("seattle_store_manager", "moderator"),
                ("atlanta_store_manager", "moderator"),
                ("austin_store_manager", "moderator"),
                ("store_analyst", "member"),
                ("viewer", "viewer"),
            ],
        },
        {
            "key": "berlin-mitte-store-ops",
            "slug": "berlin-mitte-flagship-store-ops",
            "name": "OpsAtlas Retail Store Operations",
            "region_code": "DE-BER-MIT",
            "country_code": "DE",
            "location_name": "Berlin Mitte Flagship",
            "building_code": "DE-BER-MIT-FLAG",
            "focus": "Daily floor execution and handover quality for the Berlin Mitte Flagship store.",
            "created_at": ts(days_ago=118),
            "owner_user": "berlin_store_manager",
            "space_scope": "store",
            "space_code": "berlin-mitte-flagship",
            "members": [
                ("admin", "admin"),
                ("west_region_manager", "admin"),
                ("berlin_store_manager", "moderator"),
                ("member", "member"),
                ("viewer", "viewer"),
            ],
        },
        {
            "key": "berlin-kreuzberg-store-ops",
            "slug": "berlin-kudamm-flagship-store-ops",
            "name": "OpsAtlas Retail Store Operations",
            "region_code": "DE-BER-KUD",
            "country_code": "DE",
            "location_name": "Berlin Kurfuerstendamm Flagship",
            "building_code": "DE-BER-KUD-FLAG",
            "focus": "Open/close reliability and escalation response for the Berlin Kurfuerstendamm Flagship.",
            "created_at": ts(days_ago=116),
            "owner_user": "berlin_store2_manager",
            "space_scope": "store",
            "space_code": "berlin-kudamm-flagship",
            "members": [
                ("admin", "admin"),
                ("west_region_manager", "admin"),
                ("berlin_store2_manager", "moderator"),
                ("member", "member"),
                ("viewer", "viewer"),
            ],
        },
        {
            "key": "berlin-charlottenburg-store-ops",
            "slug": "berlin-eastside-gallery-store-ops",
            "name": "OpsAtlas Retail Store Operations",
            "region_code": "DE-BER-ESG",
            "country_code": "DE",
            "location_name": "Berlin East Side Gallery Store",
            "building_code": "DE-BER-ESG-STORE",
            "focus": "Store operations and shift handover consistency for the Berlin East Side Gallery location.",
            "created_at": ts(days_ago=114),
            "owner_user": "berlin_store3_manager",
            "space_scope": "store",
            "space_code": "berlin-eastside-gallery",
            "members": [
                ("admin", "admin"),
                ("west_region_manager", "admin"),
                ("berlin_store3_manager", "moderator"),
                ("member", "member"),
                ("viewer", "viewer"),
            ],
        },
        {
            "key": "munich-store-ops",
            "slug": "munich-marienplatz-store-ops",
            "name": "OpsAtlas Retail Store Operations",
            "region_code": "DE-MUC",
            "country_code": "DE",
            "location_name": "Munich Marienplatz Store",
            "building_code": "DE-MUC-MAR-STORE",
            "focus": "Store readiness, staffing coverage, and queue monitoring for Munich Marienplatz.",
            "created_at": ts(days_ago=112),
            "owner_user": "munich_store_manager",
            "space_scope": "store",
            "space_code": "munich-marienplatz",
            "members": [
                ("admin", "admin"),
                ("east_region_manager", "admin"),
                ("munich_store_manager", "moderator"),
                ("store_analyst", "member"),
                ("viewer", "viewer"),
            ],
        },
        {
            "key": "hamburg-store-ops",
            "slug": "hamburg-jungfernstieg-store-ops",
            "name": "OpsAtlas Retail Store Operations",
            "region_code": "DE-HAM",
            "country_code": "DE",
            "location_name": "Hamburg Jungfernstieg Store",
            "building_code": "DE-HAM-JFG-STORE",
            "focus": "Store operations, hardware readiness, and escalation coverage for Hamburg Jungfernstieg.",
            "created_at": ts(days_ago=110),
            "owner_user": "hamburg_store_manager",
            "space_scope": "store",
            "space_code": "hamburg-jungfernstieg",
            "members": [
                ("admin", "admin"),
                ("east_region_manager", "admin"),
                ("hamburg_store_manager", "moderator"),
                ("store_analyst", "member"),
                ("viewer", "viewer"),
            ],
        },
        {
            "key": "paris-store-ops",
            "slug": "paris-opera-store-ops",
            "name": "OpsAtlas Retail Store Operations",
            "region_code": "FR-PAR",
            "country_code": "FR",
            "location_name": "Paris Opera Store",
            "building_code": "FR-PAR-OPR-STORE",
            "focus": "Store checklist adherence and issue triage for the Paris Opera location.",
            "created_at": ts(days_ago=108),
            "owner_user": "paris_store_manager",
            "space_scope": "store",
            "space_code": "paris-opera",
            "members": [
                ("admin", "admin"),
                ("east_region_manager", "admin"),
                ("paris_store_manager", "moderator"),
                ("store_analyst", "member"),
                ("viewer", "viewer"),
            ],
        },
        {
            "key": "austin-store-ops",
            "slug": "austin-domain-store-ops",
            "name": "OpsAtlas Retail Store Operations",
            "region_code": "US-TX-AUS",
            "country_code": "US",
            "location_name": "Austin Domain Store",
            "building_code": "US-TX-AUS-DOMAIN",
            "focus": "Store floor execution and shift handover quality for the Austin Domain location.",
            "created_at": ts(days_ago=106),
            "owner_user": "austin_store_manager",
            "space_scope": "store",
            "space_code": "austin-domain",
            "members": [
                ("admin", "admin"),
                ("eu_region_manager", "admin"),
                ("austin_store_manager", "moderator"),
                ("store_analyst", "member"),
                ("viewer", "viewer"),
            ],
        },
        {
            "key": "seattle-store-ops",
            "slug": "seattle-university-village-store-ops",
            "name": "OpsAtlas Retail Store Operations",
            "region_code": "US-WA-SEA",
            "country_code": "US",
            "location_name": "Seattle University Village Store",
            "building_code": "US-WA-SEA-UVILL",
            "focus": "Store checklists, device readiness, and queue performance for Seattle University Village.",
            "created_at": ts(days_ago=104),
            "owner_user": "seattle_store_manager",
            "space_scope": "store",
            "space_code": "seattle-university-village",
            "members": [
                ("admin", "admin"),
                ("eu_region_manager", "admin"),
                ("seattle_store_manager", "moderator"),
                ("store_analyst", "member"),
                ("member", "member"),
                ("viewer", "viewer"),
            ],
        },
        {
            "key": "atlanta-store-ops",
            "slug": "atlanta-lenox-store-ops",
            "name": "OpsAtlas Retail Store Operations",
            "region_code": "US-GA-ATL",
            "country_code": "US",
            "location_name": "Atlanta Lenox Store",
            "building_code": "US-GA-ATL-LENOX",
            "focus": "Open/close execution and local issue triage for the Atlanta Lenox location.",
            "created_at": ts(days_ago=102),
            "owner_user": "atlanta_store_manager",
            "space_scope": "store",
            "space_code": "atlanta-lenox",
            "members": [
                ("admin", "admin"),
                ("eu_region_manager", "admin"),
                ("atlanta_store_manager", "moderator"),
                ("store_analyst", "member"),
                ("viewer", "viewer"),
            ],
        },
    ]

    for idx, spec in enumerate(space_specs, start=1):
        space = get_or_create_space(
            db,
            slug=spec["slug"],
            name=spec["name"],
            created_at=spec["created_at"],
            region_code=spec.get("region_code"),
            meta={
                "scope": spec["space_scope"],
                "focus": spec["focus"],
                "space_code": spec["space_code"],
                "region_code": spec.get("region_code"),
                "country_code": spec.get("country_code"),
                "location_name": spec.get("location_name"),
                "building_code": spec.get("building_code"),
                "seed_cluster": "opsatlas-retail",
            },
        )
        refs["spaces"][spec["key"]] = space

        for user_key, role in spec["members"]:
            upsert_space_member(
                db,
                space_id=space.id,
                user_id=users[user_key].id,
                role=role,
            )

        playbooks = get_or_create_folder(db, space=space, name="Playbooks", parent=None)
        refs["folders"][f"{spec['key']}:playbooks"] = playbooks

        brief_slug = "daily-ops-brief"
        refs["docs"][f"{spec['key']}:daily-ops-brief"] = get_or_create_doc(
            db,
            space=space,
            slug=brief_slug,
            title="Daily Ops Brief",
            folder=playbooks,
            created_by=users[spec["owner_user"]],
            updated_by=users[spec["owner_user"]],
            status="published",
            created_at=ts(days_ago=32 + (idx % 6)),
            updated_at=ts(days_ago=2 + (idx % 2)),
            published_at=ts(days_ago=31 + (idx % 6)),
            content_md=md(
                [
                    "# Daily Ops Brief",
                    "",
                    spec["focus"],
                    "",
                    "## Daily Focus",
                    "- Open blockers and risks",
                    "- Staffing gaps and shift swaps",
                    "- Escalations requiring regional follow-up",
                    "- Hardware / POS readiness status",
                    "",
                    "## Metadata",
                    f"- Region code: {spec.get('region_code')}",
                    f"- Space code: {spec['space_code']}",
                ]
            ),
            versions=[
                {
                    "title": "Daily Ops Brief",
                    "content_md": md(
                        [
                            "# Daily Ops Brief",
                            "",
                            "Initial baseline for daily execution updates.",
                        ]
                    ),
                    "created_by": users[spec["owner_user"]],
                    "created_at": ts(days_ago=30),
                },
                {
                    "title": "Daily Ops Brief",
                    "content_md": md(
                        [
                            "# Daily Ops Brief",
                            "",
                            spec["focus"],
                            "",
                            "- Added staffing and hardware readiness sections.",
                        ]
                    ),
                    "created_by": users[spec["owner_user"]],
                    "created_at": ts(days_ago=2),
                },
            ],
        )

        refs["sops"][f"{spec['key']}:daily-readiness-walk"] = get_or_create_sop(
            db,
            space=space,
            slug="daily-readiness-walk",
            title="Daily Readiness Walk",
            overview_md=md(
                [
                    "Walk through opening readiness, critical hardware checks, and escalation handoff.",
                    "",
                    f"This SOP is seeded for {spec['name']} ({spec.get('region_code')}).",
                ]
            ),
            status="published",
            created_by=users[spec["owner_user"]],
            updated_by=users[spec["owner_user"]],
            created_at=ts(days_ago=20 + (idx % 5)),
            updated_at=ts(days_ago=1 + (idx % 2)),
            steps=[
                {
                    "step_order": 1,
                    "title": "Confirm shift plan",
                    "body_md": "Validate staffing coverage and confirm role handoffs.",
                },
                {
                    "step_order": 2,
                    "title": "Run hardware health checks",
                    "body_md": "Validate POS, network, and receipt printers.",
                },
                {
                    "step_order": 3,
                    "title": "Publish readiness update",
                    "body_md": "Post current status and blockers to the operations channel.",
                },
            ],
        )

        refs["incidents"][f"{spec['key']}:sample-ops-incident"] = (
            get_or_create_incident(
                db,
                key=f"{spec['key']}-sample-ops-incident",
                space=space,
                title=f"{spec['name']} - Sample Ops Incident",
                status="resolved",
                severity=2 if spec["space_scope"] == "region" else 3,
                summary_md=md(
                    [
                        "Sample incident for dashboard and timeline testing.",
                        "",
                        f"Scope: {spec['space_scope']}",
                        f"Region: {spec.get('region_code')}",
                    ]
                ),
                created_by=users[spec["owner_user"]],
                created_at=ts(days_ago=6 + (idx % 4), hours=idx % 6),
                timeline=[
                    {
                        "ts": ts(days_ago=6 + (idx % 4), hours=idx % 6),
                        "entry_md": "Incident opened after readiness check uncovered a blocking issue.",
                        "created_by": users[spec["owner_user"]],
                    },
                    {
                        "ts": ts(
                            days_ago=6 + (idx % 4), hours=(idx % 6) - 1, minutes=35
                        ),
                        "entry_md": "Mitigation applied and impacted workstream rerouted.",
                        "created_by": users["ops_analyst"],
                    },
                    {
                        "ts": ts(
                            days_ago=6 + (idx % 4), hours=(idx % 6) - 2, minutes=5
                        ),
                        "entry_md": "Resolved after validation checks passed and handoff notes were published.",
                        "created_by": users["retail_director"],
                    },
                ],
            )
        )


def seed_analytics(
    db: Session, users: dict[str, User], refs: dict[str, dict[str, Any]]
) -> None:
    events: list[dict[str, Any]] = []

    def add_views(
        *,
        key_prefix: str,
        user: User,
        space_key: str,
        entity_type: str,
        entity_key: str,
        count: int,
        start: datetime,
        every_minutes: int,
        path: str,
        surface: str,
    ) -> None:
        space = refs["spaces"][space_key]
        entity = refs[f"{entity_type}s"][entity_key]
        for i in range(count):
            events.append(
                {
                    "id": seed_uuid("event", key_prefix, str(i + 1)),
                    "ts": start + timedelta(minutes=i * every_minutes),
                    "session_id": f"{key_prefix[:24]}-{(i // 4) + 1}",
                    "event_type": "view",
                    "user": user,
                    "space": space,
                    "entity_type": entity_type,
                    "entity_id": entity.id,
                    "path": path,
                    "meta": {"surface": surface, "seed": True},
                }
            )

    add_views(
        key_prefix="platform-doc-api-release",
        user=users["admin"],
        space_key="platform-ops",
        entity_type="doc",
        entity_key="platform-ops:api-release-checklist",
        count=18,
        start=ts(days_ago=7),
        every_minutes=43,
        path=(
            f"/spaces/{refs['spaces']['platform-ops'].id}"
            "?docSlug=api-release-checklist"
        ),
        surface="kb",
    )
    add_views(
        key_prefix="platform-doc-ic-quickstart",
        user=users["moderator"],
        space_key="platform-ops",
        entity_type="doc",
        entity_key="platform-ops:incident-commander-quickstart",
        count=14,
        start=ts(days_ago=6, hours=3),
        every_minutes=57,
        path=(
            f"/spaces/{refs['spaces']['platform-ops'].id}"
            "?docSlug=incident-commander-quickstart"
        ),
        surface="kb",
    )
    add_views(
        key_prefix="platform-sop-rollback",
        user=users["member"],
        space_key="platform-ops",
        entity_type="sop",
        entity_key="platform-ops:rollback-api-release",
        count=11,
        start=ts(days_ago=4, hours=6),
        every_minutes=61,
        path=(
            f"/spaces/{refs['spaces']['platform-ops'].id}"
            f"?sopId={refs['sops']['platform-ops:rollback-api-release'].id}"
        ),
        surface="sop",
    )
    add_views(
        key_prefix="platform-inc-latency",
        user=users["admin"],
        space_key="platform-ops",
        entity_type="incident",
        entity_key="platform-ops:latency-spike-after-release",
        count=9,
        start=ts(days_ago=2, hours=10),
        every_minutes=15,
        path=(
            f"/spaces/{refs['spaces']['platform-ops'].id}"
            f"?incidentId={refs['incidents']['platform-ops:latency-spike-after-release'].id}"
        ),
        surface="incident",
    )
    add_views(
        key_prefix="store-doc-opening",
        user=users["member"],
        space_key="store-ops",
        entity_type="doc",
        entity_key="store-ops:store-opening-checklist",
        count=16,
        start=ts(days_ago=10),
        every_minutes=120,
        path=(
            f"/spaces/{refs['spaces']['store-ops'].id}"
            "?docSlug=store-opening-checklist"
        ),
        surface="kb",
    )
    add_views(
        key_prefix="store-doc-pos-health",
        user=users["member"],
        space_key="store-ops",
        entity_type="doc",
        entity_key="store-ops:pos-terminal-health-check",
        count=13,
        start=ts(days_ago=3, hours=12),
        every_minutes=87,
        path=(
            f"/spaces/{refs['spaces']['store-ops'].id}"
            "?docSlug=pos-terminal-health-check"
        ),
        surface="kb",
    )
    add_views(
        key_prefix="store-sop-printer",
        user=users["moderator"],
        space_key="store-ops",
        entity_type="sop",
        entity_key="store-ops:replace-pos-receipt-printer",
        count=10,
        start=ts(days_ago=6, hours=4),
        every_minutes=93,
        path=(
            f"/spaces/{refs['spaces']['store-ops'].id}"
            f"?sopId={refs['sops']['store-ops:replace-pos-receipt-printer'].id}"
        ),
        surface="sop",
    )
    add_views(
        key_prefix="support-doc-routing",
        user=users["moderator"],
        space_key="customer-support",
        entity_type="doc",
        entity_key="customer-support:tier1-escalation-routing",
        count=19,
        start=ts(days_ago=8, hours=1),
        every_minutes=41,
        path=(
            f"/spaces/{refs['spaces']['customer-support'].id}"
            "?docSlug=tier1-escalation-routing"
        ),
        surface="kb",
    )
    add_views(
        key_prefix="support-doc-refund-matrix",
        user=users["member"],
        space_key="customer-support",
        entity_type="doc",
        entity_key="customer-support:refund-eligibility-matrix",
        count=21,
        start=ts(days_ago=4, hours=5),
        every_minutes=37,
        path=(
            f"/spaces/{refs['spaces']['customer-support'].id}"
            "?docSlug=refund-eligibility-matrix"
        ),
        surface="kb",
    )
    add_views(
        key_prefix="support-sop-refund-delay",
        user=users["member"],
        space_key="customer-support",
        entity_type="sop",
        entity_key="customer-support:refund-delay-triage",
        count=12,
        start=ts(days_ago=3, hours=6),
        every_minutes=52,
        path=(
            f"/spaces/{refs['spaces']['customer-support'].id}"
            f"?sopId={refs['sops']['customer-support:refund-delay-triage'].id}"
        ),
        surface="sop",
    )
    add_views(
        key_prefix="support-inc-refund-delay",
        user=users["moderator"],
        space_key="customer-support",
        entity_type="incident",
        entity_key="customer-support:refund-queue-delay",
        count=8,
        start=ts(days_ago=5, hours=8),
        every_minutes=20,
        path=(
            f"/spaces/{refs['spaces']['customer-support'].id}"
            f"?incidentId={refs['incidents']['customer-support:refund-queue-delay'].id}"
        ),
        surface="incident",
    )

    # Add a few non-view events for realism.
    events.extend(
        [
            {
                "id": seed_uuid("event", "platform-search-1"),
                "ts": ts(days_ago=2, hours=8),
                "session_id": "seed-platform-search-1",
                "event_type": "search",
                "user": users["admin"],
                "space": refs["spaces"]["platform-ops"],
                "entity_type": None,
                "entity_id": None,
                "path": f"/spaces/{refs['spaces']['platform-ops'].id}",
                "meta": {
                    "query": "rollback",
                    "result_count": 3,
                    "surface": "global-search",
                },
            },
            {
                "id": seed_uuid("event", "support-search-1"),
                "ts": ts(days_ago=1, hours=4),
                "session_id": "seed-support-search-1",
                "event_type": "search",
                "user": users["member"],
                "space": refs["spaces"]["customer-support"],
                "entity_type": None,
                "entity_id": None,
                "path": f"/spaces/{refs['spaces']['customer-support'].id}",
                "meta": {
                    "query": "refund",
                    "result_count": 5,
                    "surface": "global-search",
                },
            },
            {
                "id": seed_uuid("event", "store-publish-note"),
                "ts": ts(days_ago=1, hours=2),
                "session_id": "seed-store-publish-1",
                "event_type": "publish",
                "user": users["moderator"],
                "space": refs["spaces"]["store-ops"],
                "entity_type": "doc",
                "entity_id": refs["docs"]["store-ops:pos-terminal-health-check"].id,
                "path": (
                    f"/spaces/{refs['spaces']['store-ops'].id}"
                    "?docSlug=pos-terminal-health-check"
                ),
                "meta": {"source": "seed", "reason": "daily checklist update"},
            },
        ]
    )

    for e in events:
        upsert_event(
            db,
            event_id=e["id"],
            ts_value=e["ts"],
            session_id=e["session_id"],
            event_type=e["event_type"],
            user=e["user"],
            space=e["space"],
            entity_type=e["entity_type"],
            entity_id=e["entity_id"],
            path=e["path"],
            meta=e["meta"],
        )


def seed_extended_org_and_access(
    db: Session, users: dict[str, User], refs: dict[str, dict[str, Any]]
) -> None:
    for space_key, user_key, role in [
        ("platform-ops", "platform_lead", "moderator"),
        ("platform-ops", "ops_analyst", "member"),
        ("platform-ops", "compliance", "viewer"),
        ("store-ops", "retail_director", "admin"),
        ("store-ops", "ops_analyst", "moderator"),
        ("store-ops", "compliance", "viewer"),
        ("berlin-region-ops", "west_region_manager", "admin"),
        ("central-europe-region-ops", "east_region_manager", "admin"),
        ("north-america-region-ops", "eu_region_manager", "admin"),
        ("berlin-mitte-store-ops", "berlin_store_manager", "moderator"),
        ("berlin-kreuzberg-store-ops", "berlin_store2_manager", "moderator"),
        ("berlin-charlottenburg-store-ops", "berlin_store3_manager", "moderator"),
        ("munich-store-ops", "munich_store_manager", "moderator"),
        ("hamburg-store-ops", "hamburg_store_manager", "moderator"),
        ("paris-store-ops", "paris_store_manager", "moderator"),
        ("austin-store-ops", "austin_store_manager", "moderator"),
        ("seattle-store-ops", "seattle_store_manager", "moderator"),
        ("atlanta-store-ops", "atlanta_store_manager", "moderator"),
        ("customer-support", "support_qa", "moderator"),
        ("customer-support", "retail_director", "viewer"),
        ("customer-support", "compliance", "member"),
    ]:
        upsert_space_member(
            db,
            space_id=refs["spaces"][space_key].id,
            user_id=users[user_key].id,
            role=role,
        )

    get_or_create_custom_role(
        db,
        role_key="release_manager",
        name="Release Manager",
        description="Owns release readiness, rollback decisions, and operational coordination for platform changes.",
        effective_level="moderator",
        active=True,
    )
    get_or_create_custom_role(
        db,
        role_key="regional_director",
        name="Regional Director",
        description="Oversees multiple stores and can coordinate approvals that affect retail operations.",
        effective_level="admin",
        active=True,
    )
    get_or_create_custom_role(
        db,
        role_key="shift_lead",
        name="Shift Lead",
        description="Coordinates store floor execution and ensures checklists are followed during open and close.",
        effective_level="member",
        active=True,
    )
    get_or_create_custom_role(
        db,
        role_key="support_qa",
        name="Support QA",
        description="Reviews escalations, documentation quality, and response consistency for the support org.",
        effective_level="member",
        active=True,
    )
    get_or_create_custom_role(
        db,
        role_key="store_manager",
        name="Store Manager",
        description="Owns day-to-day store execution, incident follow-up, and shift handovers.",
        effective_level="moderator",
        active=True,
    )
    get_or_create_custom_role(
        db,
        role_key="merchandising_planner",
        name="Merchandising Planner",
        description="Coordinates assortment, campaign timing, and regional merchandising changes.",
        effective_level="member",
        active=True,
    )

    berlin_region = get_or_create_org_unit(
        db,
        slug="emea-north-region",
        name="EMEA North Region",
        unit_type="region",
        parent=None,
        active=True,
        created_at=ts(days_ago=160),
        updated_at=ts(days_ago=2),
        meta={
            "region_code": "DE-BER",
            "scope": "region",
            "country_code": "DE",
            "management_layer": "regional",
            "seed_cluster": "opsatlas-retail",
        },
    )
    central_europe_region = get_or_create_org_unit(
        db,
        slug="emea-central-region",
        name="EMEA Central Region",
        unit_type="region",
        parent=None,
        active=True,
        created_at=ts(days_ago=158),
        updated_at=ts(days_ago=2),
        meta={
            "region_code": "EU-CENTRAL",
            "scope": "region",
            "country_code": "EU",
            "management_layer": "regional",
            "seed_cluster": "opsatlas-retail",
        },
    )
    north_america_region = get_or_create_org_unit(
        db,
        slug="americas-region",
        name="Americas Region",
        unit_type="region",
        parent=None,
        active=True,
        created_at=ts(days_ago=156),
        updated_at=ts(days_ago=2),
        meta={
            "region_code": "NA",
            "scope": "region",
            "country_code": "US",
            "management_layer": "regional",
            "seed_cluster": "opsatlas-retail",
        },
    )

    ops_command_center = get_or_create_org_unit(
        db,
        slug="ops-command-center",
        name="Global Ops Command Center",
        unit_type="department",
        parent=None,
        active=True,
        created_at=ts(days_ago=150),
        updated_at=ts(days_ago=1),
        meta={
            "department_code": "OPS-CC",
            "scope": "department",
            "seed_cluster": "opsatlas-core",
        },
    )

    berlin_mitte = get_or_create_org_unit(
        db,
        slug="berlin-mitte-flagship-store",
        name="Berlin Mitte Flagship Store",
        unit_type="store",
        parent=berlin_region,
        active=True,
        created_at=ts(days_ago=145),
        updated_at=ts(days_ago=2),
        meta={
            "store_code": "BER-MIT-FLAG",
            "region_code": "DE-BER",
            "scope": "store",
            "building_code": "DE-BER-MIT-FLAG",
            "location_name": "Berlin Mitte Flagship",
        },
    )
    berlin_kudamm = get_or_create_org_unit(
        db,
        slug="berlin-kudamm-flagship-store",
        name="Berlin Kurfuerstendamm Flagship Store",
        unit_type="store",
        parent=berlin_region,
        active=True,
        created_at=ts(days_ago=143),
        updated_at=ts(days_ago=2),
        meta={
            "store_code": "BER-KUD-FLAG",
            "region_code": "DE-BER",
            "scope": "store",
            "building_code": "DE-BER-KUD-FLAG",
            "location_name": "Berlin Kurfuerstendamm Flagship",
        },
    )
    berlin_eastside = get_or_create_org_unit(
        db,
        slug="berlin-eastside-gallery-store",
        name="Berlin East Side Gallery Store",
        unit_type="store",
        parent=berlin_region,
        active=True,
        created_at=ts(days_ago=141),
        updated_at=ts(days_ago=2),
        meta={
            "store_code": "BER-ESG-STORE",
            "region_code": "DE-BER",
            "scope": "store",
            "building_code": "DE-BER-ESG-STORE",
            "location_name": "Berlin East Side Gallery",
        },
    )
    munich_marienplatz = get_or_create_org_unit(
        db,
        slug="munich-marienplatz-store",
        name="Munich Marienplatz Store",
        unit_type="store",
        parent=central_europe_region,
        active=True,
        created_at=ts(days_ago=139),
        updated_at=ts(days_ago=2),
        meta={
            "store_code": "MUC-MAR",
            "region_code": "EU-CENTRAL",
            "scope": "store",
            "building_code": "DE-MUC-MAR-STORE",
            "location_name": "Munich Marienplatz",
        },
    )
    hamburg_jungfernstieg = get_or_create_org_unit(
        db,
        slug="hamburg-jungfernstieg-store",
        name="Hamburg Jungfernstieg Store",
        unit_type="store",
        parent=central_europe_region,
        active=True,
        created_at=ts(days_ago=137),
        updated_at=ts(days_ago=2),
        meta={
            "store_code": "HAM-JFG",
            "region_code": "EU-CENTRAL",
            "scope": "store",
            "building_code": "DE-HAM-JFG-STORE",
            "location_name": "Hamburg Jungfernstieg",
        },
    )
    paris_opera = get_or_create_org_unit(
        db,
        slug="paris-opera-store",
        name="Paris Opera Store",
        unit_type="store",
        parent=central_europe_region,
        active=True,
        created_at=ts(days_ago=135),
        updated_at=ts(days_ago=2),
        meta={
            "store_code": "PAR-OPR",
            "region_code": "EU-CENTRAL",
            "scope": "store",
            "building_code": "FR-PAR-OPR-STORE",
            "location_name": "Paris Opera",
        },
    )
    austin_domain = get_or_create_org_unit(
        db,
        slug="austin-domain-store",
        name="Austin Domain Store",
        unit_type="store",
        parent=north_america_region,
        active=True,
        created_at=ts(days_ago=133),
        updated_at=ts(days_ago=2),
        meta={
            "store_code": "AUS-DOM",
            "region_code": "NA",
            "scope": "store",
            "building_code": "US-TX-AUS-DOMAIN",
            "location_name": "Austin Domain",
        },
    )
    seattle_university_village = get_or_create_org_unit(
        db,
        slug="seattle-university-village-store",
        name="Seattle University Village Store",
        unit_type="store",
        parent=north_america_region,
        active=True,
        created_at=ts(days_ago=131),
        updated_at=ts(days_ago=2),
        meta={
            "store_code": "SEA-UVILL",
            "region_code": "NA",
            "scope": "store",
            "building_code": "US-WA-SEA-UVILL",
            "location_name": "Seattle University Village",
        },
    )
    atlanta_lenox = get_or_create_org_unit(
        db,
        slug="atlanta-lenox-store",
        name="Atlanta Lenox Store",
        unit_type="store",
        parent=north_america_region,
        active=True,
        created_at=ts(days_ago=129),
        updated_at=ts(days_ago=2),
        meta={
            "store_code": "ATL-LENOX",
            "region_code": "NA",
            "scope": "store",
            "building_code": "US-GA-ATL-LENOX",
            "location_name": "Atlanta Lenox",
        },
    )

    profile_map = {
        "admin": ([ops_command_center], None),
        "moderator": ([ops_command_center], "release_manager"),
        "member": ([berlin_mitte], "shift_lead"),
        "viewer": ([berlin_mitte], None),
        "platform_lead": ([ops_command_center], "release_manager"),
        "retail_director": (
            [berlin_region, central_europe_region, north_america_region],
            "regional_director",
        ),
        "support_qa": ([ops_command_center], "support_qa"),
        "ops_analyst": ([ops_command_center, north_america_region], None),
        "compliance": ([central_europe_region], None),
        "west_region_manager": ([berlin_region], "regional_director"),
        "east_region_manager": ([central_europe_region], "regional_director"),
        "eu_region_manager": ([north_america_region], "regional_director"),
        "seattle_store_manager": (
            [seattle_university_village, north_america_region],
            "store_manager",
        ),
        "atlanta_store_manager": (
            [atlanta_lenox, north_america_region],
            "store_manager",
        ),
        "berlin_store_manager": ([berlin_mitte, berlin_region], "store_manager"),
        "berlin_store2_manager": ([berlin_kudamm, berlin_region], "store_manager"),
        "berlin_store3_manager": ([berlin_eastside, berlin_region], "store_manager"),
        "munich_store_manager": (
            [munich_marienplatz, central_europe_region],
            "store_manager",
        ),
        "hamburg_store_manager": (
            [hamburg_jungfernstieg, central_europe_region],
            "store_manager",
        ),
        "paris_store_manager": ([paris_opera, central_europe_region], "store_manager"),
        "austin_store_manager": (
            [austin_domain, north_america_region],
            "store_manager",
        ),
        "ops_command_manager": ([ops_command_center], "release_manager"),
        "merchandising_manager": ([ops_command_center], "merchandising_planner"),
        "store_analyst": ([north_america_region], None),
    }

    def attach_user_profile(
        user_key: str,
        org_units: list[OrganizationUnit],
        role_key: str | None = None,
    ) -> None:
        user = users[user_key]
        current_meta = {}
        if isinstance(user.meta_json, str) and user.meta_json.strip():
            try:
                decoded = json.loads(user.meta_json)
                if isinstance(decoded, dict):
                    current_meta = decoded
            except Exception:
                current_meta = {}
        current_meta["employment_document_url"] = (
            f"/media/dummy/employment/{user_key}.pdf"
        )
        current_meta["department_count"] = len(org_units)
        current_meta["org_primary_unit_slug"] = org_units[0].slug
        current_meta["seed_profile_version"] = "opsatlas-v2"
        # Legacy role-in-meta is fully retired. Roles are represented by role->user item-links.
        current_meta.pop("custom_role_key", None)
        user.meta_json = json.dumps(
            current_meta, ensure_ascii=False, separators=(",", ":")
        )
        for org_unit in org_units:
            upsert_org_item_link(
                db,
                parent_kind="department",
                parent_id=org_unit.id,
                child_kind="user",
                child_id=user.id,
                grant_role="member",
                inherit_to_descendants=True,
                active=True,
            )
        if role_key:
            upsert_org_item_link(
                db,
                parent_kind="role",
                parent_id=role_key.strip().lower(),
                child_kind="user",
                child_id=user.id,
                grant_role=role_key.strip().lower(),
                inherit_to_descendants=False,
                active=True,
            )

    for user_key, (org_units, role_key) in profile_map.items():
        attach_user_profile(user_key, org_units, role_key)

    def link_report(report_key: str, manager_key: str) -> None:
        upsert_org_item_link(
            db,
            parent_kind="user",
            parent_id=users[manager_key].id,
            child_kind="user",
            child_id=users[report_key].id,
            grant_role="member",
            inherit_to_descendants=True,
            active=True,
        )

    manager_links = [
        ("platform_lead", "admin"),
        ("ops_command_manager", "platform_lead"),
        ("ops_analyst", "platform_lead"),
        ("support_qa", "ops_command_manager"),
        ("retail_director", "admin"),
        ("west_region_manager", "retail_director"),  # Berlin region manager
        ("east_region_manager", "retail_director"),  # Central Europe region manager
        ("eu_region_manager", "retail_director"),  # North America region manager
        ("seattle_store_manager", "eu_region_manager"),
        ("atlanta_store_manager", "eu_region_manager"),
        ("austin_store_manager", "eu_region_manager"),
        ("berlin_store_manager", "west_region_manager"),
        ("berlin_store2_manager", "west_region_manager"),
        ("berlin_store3_manager", "west_region_manager"),
        ("munich_store_manager", "east_region_manager"),
        ("hamburg_store_manager", "east_region_manager"),
        ("paris_store_manager", "east_region_manager"),
        ("member", "berlin_store_manager"),
        ("viewer", "berlin_store_manager"),
        ("store_analyst", "eu_region_manager"),
        ("compliance", "east_region_manager"),
        ("merchandising_manager", "ops_command_manager"),
    ]
    for report_key, manager_key in manager_links:
        link_report(report_key, manager_key)

    store_unit_map: dict[str, OrganizationUnit] = {
        "berlin_mitte": berlin_mitte,
        "berlin_kudamm": berlin_kudamm,
        "berlin_eastside": berlin_eastside,
        "munich_marienplatz": munich_marienplatz,
        "hamburg_jungfernstieg": hamburg_jungfernstieg,
        "paris_opera": paris_opera,
        "austin_domain": austin_domain,
        "seattle_university_village": seattle_university_village,
        "atlanta_lenox": atlanta_lenox,
    }
    store_region_map: dict[str, OrganizationUnit] = {
        "berlin_mitte": berlin_region,
        "berlin_kudamm": berlin_region,
        "berlin_eastside": berlin_region,
        "munich_marienplatz": central_europe_region,
        "hamburg_jungfernstieg": central_europe_region,
        "paris_opera": central_europe_region,
        "austin_domain": north_america_region,
        "seattle_university_village": north_america_region,
        "atlanta_lenox": north_america_region,
    }
    store_manager_map: dict[str, str] = {
        "berlin_mitte": "berlin_store_manager",
        "berlin_kudamm": "berlin_store2_manager",
        "berlin_eastside": "berlin_store3_manager",
        "munich_marienplatz": "munich_store_manager",
        "hamburg_jungfernstieg": "hamburg_store_manager",
        "paris_opera": "paris_store_manager",
        "austin_domain": "austin_store_manager",
        "seattle_university_village": "seattle_store_manager",
        "atlanta_lenox": "atlanta_store_manager",
    }
    for alias, store_unit in store_unit_map.items():
        for idx in range(1, 7):
            user_key = f"store_{alias}_associate_{idx:02d}"
            memberships = [store_unit]
            if idx in (1, 4):
                memberships.append(store_region_map[alias])
            custom_role = "shift_lead" if idx == 1 else None
            attach_user_profile(user_key, memberships, custom_role)
            link_report(user_key, store_manager_map[alias])

    region_unit_map: dict[str, tuple[OrganizationUnit, str, list[OrganizationUnit]]] = {
        "emea_north": (
            berlin_region,
            "west_region_manager",
            [berlin_mitte, berlin_kudamm, berlin_eastside],
        ),
        "emea_central": (
            central_europe_region,
            "east_region_manager",
            [munich_marienplatz, hamburg_jungfernstieg, paris_opera],
        ),
        "americas": (
            north_america_region,
            "eu_region_manager",
            [austin_domain, seattle_university_village, atlanta_lenox],
        ),
    }
    for alias, (region_unit, manager_key, store_cycle) in region_unit_map.items():
        for idx in range(1, 5):
            user_key = f"region_{alias}_coordinator_{idx:02d}"
            memberships = [region_unit]
            if idx in (2, 4):
                memberships.append(store_cycle[(idx - 1) % len(store_cycle)])
            attach_user_profile(user_key, memberships, None)
            link_report(user_key, manager_key)

    corp_assignments: list[tuple[str, str, list[OrganizationUnit], str | None]] = [
        (
            "corp_supply_chain_specialist",
            "retail_director",
            [ops_command_center, central_europe_region],
            None,
        ),
        (
            "corp_people_ops_specialist",
            "ops_command_manager",
            [ops_command_center],
            None,
        ),
        (
            "corp_it_service_specialist",
            "ops_command_manager",
            [ops_command_center, north_america_region],
            "release_manager",
        ),
        (
            "corp_training_specialist",
            "ops_command_manager",
            [ops_command_center, berlin_region],
            None,
        ),
        (
            "corp_finance_ops_specialist",
            "ops_command_manager",
            [ops_command_center],
            None,
        ),
        (
            "corp_visual_merch_specialist",
            "merchandising_manager",
            [ops_command_center, central_europe_region],
            "merchandising_planner",
        ),
        (
            "corp_facilities_specialist",
            "ops_command_manager",
            [ops_command_center, berlin_region],
            None,
        ),
        (
            "corp_security_specialist",
            "ops_command_manager",
            [ops_command_center, north_america_region],
            None,
        ),
        (
            "corp_quality_specialist",
            "ops_command_manager",
            [ops_command_center, central_europe_region],
            None,
        ),
        (
            "corp_field_engineering_specialist",
            "ops_command_manager",
            [ops_command_center, north_america_region],
            "release_manager",
        ),
    ]
    for user_key, manager_key, memberships, custom_role in corp_assignments:
        attach_user_profile(user_key, memberships, custom_role)
        link_report(user_key, manager_key)

    upsert_row(
        db,
        BrandingSettings,
        pk_field="id",
        pk_value=1,
        company_name="OpsAtlas Operations Cloud",
        logo_url=None,
        light_seed_hex="#0F6CBD",
        dark_accent_hex="#1D9BF0",
        dark_bg_hex="#0B141F",
        updated_at=ts(days_ago=1),
    )

    space_links: list[tuple[OrganizationUnit, str, str, bool]] = [
        # One companywide space linked to all regions + ops command center.
        (ops_command_center, "platform-ops", "admin", True),
        (berlin_region, "platform-ops", "viewer", True),
        (central_europe_region, "platform-ops", "viewer", True),
        (north_america_region, "platform-ops", "viewer", True),
        # Shared operational/support hubs.
        (ops_command_center, "store-ops", "member", True),
        (ops_command_center, "customer-support", "member", True),
        # Region spaces.
        (berlin_region, "berlin-region-ops", "admin", True),
        (central_europe_region, "central-europe-region-ops", "admin", True),
        (north_america_region, "north-america-region-ops", "admin", True),
        # Store spaces.
        (berlin_mitte, "berlin-mitte-store-ops", "moderator", False),
        (berlin_kudamm, "berlin-kreuzberg-store-ops", "moderator", False),
        (berlin_eastside, "berlin-charlottenburg-store-ops", "moderator", False),
        (munich_marienplatz, "munich-store-ops", "moderator", False),
        (hamburg_jungfernstieg, "hamburg-store-ops", "moderator", False),
        (paris_opera, "paris-store-ops", "moderator", False),
        (austin_domain, "austin-store-ops", "moderator", False),
        (seattle_university_village, "seattle-store-ops", "moderator", False),
        (atlanta_lenox, "atlanta-store-ops", "moderator", False),
    ]
    for parent_unit, space_key, grant_role, inherit in space_links:
        upsert_org_item_link(
            db,
            parent_kind="department",
            parent_id=parent_unit.id,
            child_kind="space",
            child_id=refs["spaces"][space_key].id,
            grant_role=grant_role,
            inherit_to_descendants=inherit,
            active=True,
        )

    notification_profiles = {
        "admin": (True, True, True, True, "realtime", 9, 0, ts(days_ago=1)),
        "moderator": (True, True, True, True, "hourly", 10, 30, ts(days_ago=2)),
        "member": (False, True, True, True, "daily", 8, 15, ts(days_ago=3)),
        "platform_lead": (True, True, True, True, "daily", 9, 0, ts(days_ago=2)),
        "ops_command_manager": (
            True,
            True,
            True,
            True,
            "hourly",
            9,
            15,
            ts(days_ago=1),
        ),
        "support_qa": (False, True, True, True, "hourly", 11, 0, ts(days_ago=1)),
        "west_region_manager": (
            True,
            True,
            True,
            True,
            "hourly",
            8,
            30,
            ts(days_ago=1),
        ),
        "east_region_manager": (
            True,
            True,
            True,
            True,
            "hourly",
            8,
            45,
            ts(days_ago=1),
        ),
        "eu_region_manager": (True, True, True, True, "daily", 7, 30, ts(days_ago=1)),
        "austin_store_manager": (
            True,
            True,
            True,
            True,
            "daily",
            6,
            30,
            ts(days_ago=1),
        ),
        "seattle_store_manager": (
            True,
            True,
            True,
            True,
            "daily",
            6,
            45,
            ts(days_ago=1),
        ),
        "atlanta_store_manager": (
            True,
            True,
            True,
            True,
            "daily",
            6,
            45,
            ts(days_ago=1),
        ),
        "berlin_store_manager": (
            True,
            True,
            True,
            True,
            "daily",
            7,
            15,
            ts(days_ago=1),
        ),
        "berlin_store2_manager": (
            True,
            True,
            True,
            True,
            "daily",
            7,
            10,
            ts(days_ago=1),
        ),
        "berlin_store3_manager": (
            True,
            True,
            True,
            True,
            "daily",
            7,
            20,
            ts(days_ago=1),
        ),
        "munich_store_manager": (True, True, True, True, "daily", 7, 0, ts(days_ago=1)),
        "hamburg_store_manager": (
            True,
            True,
            True,
            True,
            "daily",
            7,
            5,
            ts(days_ago=1),
        ),
        "paris_store_manager": (True, True, True, True, "daily", 7, 25, ts(days_ago=1)),
        "merchandising_manager": (
            True,
            True,
            True,
            True,
            "daily",
            9,
            15,
            ts(days_ago=1),
        ),
    }
    for user_key, (
        include_view,
        include_search,
        include_publish,
        include_task,
        digest_mode,
        hour,
        minute,
        updated_at,
    ) in notification_profiles.items():
        upsert_row(
            db,
            UserNotificationPreference,
            pk_field="user_id",
            pk_value=users[user_key].id,
            include_view=include_view,
            include_search=include_search,
            include_publish=include_publish,
            include_task=include_task,
            digest_mode=digest_mode,
            digest_hour=hour,
            digest_minute=minute,
            updated_at=updated_at,
        )

    audit_rows = [
        (
            "admin",
            "admin",
            "include_view,include_search,digest_mode",
            True,
            True,
            True,
            True,
            "realtime",
            9,
            0,
            ts(days_ago=9),
        ),
        (
            "member",
            "moderator",
            "include_task,digest_mode,digest_hour,digest_minute",
            False,
            True,
            True,
            True,
            "daily",
            8,
            15,
            ts(days_ago=6),
        ),
        (
            "support_qa",
            "admin",
            "include_search,digest_mode",
            False,
            True,
            True,
            True,
            "hourly",
            11,
            0,
            ts(days_ago=3),
        ),
    ]
    for (
        user_key,
        actor_key,
        changed_keys_csv,
        include_view,
        include_search,
        include_publish,
        include_task,
        digest_mode,
        hour,
        minute,
        changed_at,
    ) in audit_rows:
        upsert_row(
            db,
            UserNotificationPreferenceAudit,
            pk_field="id",
            pk_value=seed_uuid(
                "notification-audit",
                user_key,
                actor_key,
                changed_keys_csv,
                changed_at.isoformat(),
            ),
            user_id=users[user_key].id,
            actor_user_id=users[actor_key].id,
            changed_keys_csv=changed_keys_csv,
            include_view=include_view,
            include_search=include_search,
            include_publish=include_publish,
            include_task=include_task,
            digest_mode=digest_mode,
            digest_hour=hour,
            digest_minute=minute,
            changed_at=changed_at,
        )


def seed_auth_runtime_demo(
    db: Session, users: dict[str, User], refs: dict[str, dict[str, Any]]
) -> None:
    upsert_row(
        db,
        AuthSessionPolicy,
        pk_field="id",
        pk_value=1,
        allow_remember_device=True,
        default_profile="remember_device",
        this_browser_days=2,
        remember_device_days=21,
        warning_minutes=20,
        updated_at=ts(days_ago=1, hours=3),
    )

    dashboard_profiles = [
        (
            "admin",
            "platform-ops",
            [
                "profile_actions",
                "activity_feed",
                "incident_queue",
                "my_tasks",
                "due_runs",
                "mentions",
                "spaces_overview",
            ],
            [],
            ts(days_ago=0, hours=1),
        ),
        (
            "platform_lead",
            "platform-ops",
            [
                "incident_queue",
                "activity_feed",
                "my_tasks",
                "due_runs",
                "mentions",
                "spaces_overview",
            ],
            ["profile_actions"],
            ts(days_ago=0, hours=2),
        ),
        (
            "retail_director",
            "store-ops",
            [
                "incident_queue",
                "spaces_overview",
                "my_tasks",
                "activity_feed",
                "due_runs",
                "mentions",
            ],
            ["profile_actions"],
            ts(days_ago=0, hours=5),
        ),
        (
            "support_qa",
            "customer-support",
            [
                "my_tasks",
                "mentions",
                "incident_queue",
                "activity_feed",
                "due_runs",
                "spaces_overview",
            ],
            ["profile_actions"],
            ts(days_ago=0, hours=4),
        ),
        (
            "berlin_store_manager",
            "berlin-mitte-store-ops",
            [
                "my_tasks",
                "incident_queue",
                "due_runs",
                "activity_feed",
                "spaces_overview",
            ],
            ["mentions", "profile_actions"],
            ts(days_ago=0, hours=7),
        ),
        (
            "austin_store_manager",
            "austin-store-ops",
            [
                "my_tasks",
                "due_runs",
                "incident_queue",
                "activity_feed",
                "spaces_overview",
            ],
            ["mentions", "profile_actions"],
            ts(days_ago=0, hours=9),
        ),
    ]
    for (
        user_key,
        space_key,
        widget_order,
        hidden_widgets,
        feed_seen_at,
    ) in dashboard_profiles:
        upsert_row(
            db,
            UserDashboardPreference,
            pk_field="user_id",
            pk_value=users[user_key].id,
            selected_space_id=refs["spaces"][space_key].id,
            widget_order_json=json.dumps(widget_order, separators=(",", ":")),
            hidden_widgets_json=json.dumps(hidden_widgets, separators=(",", ":")),
            feed_seen_at=feed_seen_at,
            updated_at=feed_seen_at,
        )

    mfa_user_keys = {"admin", "platform_lead", "support_qa"}
    user_last_login_days = {
        "admin": 0,
        "platform_lead": 0,
        "retail_director": 0,
        "support_qa": 0,
        "ops_analyst": 1,
        "berlin_store_manager": 1,
        "austin_store_manager": 1,
        "viewer": 6,
    }
    for user_key, user in users.items():
        last_login_at = ts(days_ago=user_last_login_days.get(user_key, 3), hours=2)
        failed_attempts = 0
        last_failed_login_at = None
        lockout_until = None
        if user_key == "viewer":
            failed_attempts = 1
            last_failed_login_at = ts(days_ago=6, hours=5)
        upsert_row(
            db,
            UserSecurityState,
            pk_field="user_id",
            pk_value=user.id,
            failed_login_attempts=failed_attempts,
            last_failed_login_at=last_failed_login_at,
            lockout_until=lockout_until,
            last_login_at=last_login_at,
            mfa_enabled=user_key in mfa_user_keys,
            mfa_secret="JBSWY3DPEHPK3PXP" if user_key in mfa_user_keys else None,
            mfa_enrolled_at=ts(days_ago=45) if user_key in mfa_user_keys else None,
            last_mfa_verified_at=ts(days_ago=0, hours=2)
            if user_key in mfa_user_keys
            else None,
            session_invalid_before=None,
            created_at=user.created_at or ts(days_ago=60),
            updated_at=ts(days_ago=0, hours=1),
        )

    session_specs = [
        (
            "admin",
            "macbook-current",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 Safari/605.1.15",
            "192.168.10.12",
            ts(days_ago=9),
            BASE_TS + timedelta(days=21),
            None,
            None,
            ts(days_ago=0, hours=1),
            ts(days_ago=0, hours=1),
            ts(days_ago=0, hours=1),
            True,
        ),
        (
            "admin",
            "ipad-review",
            "Mozilla/5.0 (iPad; CPU OS 18_3 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
            "192.168.10.18",
            ts(days_ago=4),
            BASE_TS + timedelta(days=17),
            None,
            None,
            ts(days_ago=0, hours=9),
            ts(days_ago=0, hours=9),
            ts(days_ago=0, hours=9),
            True,
        ),
        (
            "admin",
            "old-chrome",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/136.0.0.0 Safari/537.36",
            "10.0.0.42",
            ts(days_ago=13),
            BASE_TS + timedelta(days=8),
            ts(days_ago=2, hours=1),
            "revoke_all_except_current",
            ts(days_ago=2, hours=1),
            ts(days_ago=2, hours=1),
            ts(days_ago=3),
            False,
        ),
        (
            "platform_lead",
            "work-laptop",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/537.36 Chrome/136.0.0.0 Safari/537.36",
            "10.14.6.24",
            ts(days_ago=7),
            BASE_TS + timedelta(days=19),
            None,
            None,
            ts(days_ago=0, hours=3),
            ts(days_ago=0, hours=3),
            ts(days_ago=0, hours=3),
            True,
        ),
        (
            "retail_director",
            "office-browser",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 Safari/605.1.15",
            "172.18.20.14",
            ts(days_ago=6),
            BASE_TS + timedelta(days=18),
            None,
            None,
            ts(days_ago=0, hours=6),
            ts(days_ago=0, hours=6),
            ts(days_ago=0, hours=6),
            False,
        ),
        (
            "support_qa",
            "support-floor",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/136.0.0.0 Safari/537.36",
            "172.22.4.88",
            ts(days_ago=5),
            BASE_TS + timedelta(days=12),
            None,
            None,
            ts(days_ago=0, hours=5),
            ts(days_ago=0, hours=5),
            ts(days_ago=0, hours=5),
            True,
        ),
        (
            "berlin_store_manager",
            "store-ipad",
            "Mozilla/5.0 (iPad; CPU OS 18_3 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
            "10.42.0.19",
            ts(days_ago=3),
            BASE_TS + timedelta(days=9),
            None,
            None,
            ts(days_ago=0, hours=11),
            ts(days_ago=0, hours=11),
            ts(days_ago=0, hours=11),
            False,
        ),
        (
            "austin_store_manager",
            "store-iphone",
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
            "10.51.8.22",
            ts(days_ago=2),
            BASE_TS + timedelta(days=8),
            None,
            None,
            ts(days_ago=0, hours=12),
            ts(days_ago=0, hours=12),
            ts(days_ago=0, hours=12),
            False,
        ),
    ]
    for (
        user_key,
        session_key,
        user_agent,
        ip_address,
        created_at,
        refresh_expires_at,
        revoked_at,
        revoke_reason,
        last_seen_at,
        last_rotated_at,
        updated_at,
        mfa_verified,
    ) in session_specs:
        upsert_row(
            db,
            UserSession,
            pk_field="id",
            pk_value=seed_uuid("user-session", user_key, session_key),
            user_id=users[user_key].id,
            refresh_token_hash=_seed_refresh_token_hash(user_key, session_key),
            refresh_expires_at=refresh_expires_at,
            revoked_at=revoked_at,
            revoke_reason=revoke_reason,
            ip_address=ip_address,
            user_agent=user_agent,
            mfa_verified_at=created_at + timedelta(minutes=5) if mfa_verified else None,
            created_at=created_at,
            updated_at=updated_at,
            last_seen_at=last_seen_at,
            last_rotated_at=last_rotated_at,
        )


def seed_tasks_and_activity(
    db: Session, users: dict[str, User], refs: dict[str, dict[str, Any]]
) -> None:
    task_specs = [
        {
            "key": "platform-ops:analytics-query-guardrail",
            "space": refs["spaces"]["platform-ops"],
            "title": "Cap analytics query fan-out before the next release",
            "description": "Add a hard upper bound to the analytics aggregate query path and document the rollout fallback. This is the follow-up from the latency spike postmortem.",
            "status": "in_progress",
            "priority": "high",
            "assignee": users["platform_lead"],
            "created_by": users["admin"],
            "source_kind": "incident",
            "source_id": refs["incidents"][
                "platform-ops:latency-spike-after-release"
            ].id,
            "due_at": BASE_TS + timedelta(days=3),
            "created_at": ts(days_ago=4),
            "updated_at": ts(days_ago=1, hours=4),
        },
        {
            "key": "platform-ops:backup-timeout-dashboard",
            "space": refs["spaces"]["platform-ops"],
            "title": "Add backup proxy timeout telemetry to the operations dashboard",
            "description": "Expose tree browse latency, timeout counts, and large-tree request sizes so the backup browsing issue can be tracked without manual QA notes.",
            "status": "todo",
            "priority": "medium",
            "assignee": users["ops_analyst"],
            "created_by": users["moderator"],
            "source_kind": "incident",
            "source_id": refs["incidents"]["platform-ops:backup-proxy-timeouts"].id,
            "due_at": BASE_TS + timedelta(days=5),
            "created_at": ts(days_ago=2, hours=6),
            "updated_at": ts(days_ago=2, hours=6),
        },
        {
            "key": "store-ops:printer-asset-labels",
            "space": refs["spaces"]["store-ops"],
            "title": "Roll out new receipt printer asset labels for Austin pilot lanes",
            "description": "Label the replacement printers and USB cable kits so the field team can track repeat hardware failures by lane.",
            "status": "blocked",
            "priority": "medium",
            "assignee": users["member"],
            "created_by": users["retail_director"],
            "source_kind": "sop",
            "source_id": refs["sops"]["store-ops:replace-pos-receipt-printer"].id,
            "due_at": BASE_TS + timedelta(days=2),
            "created_at": ts(days_ago=3, hours=4),
            "updated_at": ts(days_ago=1, hours=8),
        },
        {
            "key": "store-ops:weekend-opening-review",
            "space": refs["spaces"]["store-ops"],
            "title": "Review weekend opening checklist with Austin shift leads",
            "description": "Walk through the updated store opening checklist and verify the curbside pickup board handoff is being done consistently.",
            "status": "done",
            "priority": "low",
            "assignee": users["retail_director"],
            "created_by": users["moderator"],
            "source_kind": "sop",
            "source_id": refs["sops"]["store-ops:inventory-recount-escalation"].id,
            "due_at": ts(days_ago=1),
            "created_at": ts(days_ago=8),
            "updated_at": ts(days_ago=1),
        },
        {
            "key": "customer-support:refund-macro-refresh",
            "space": refs["spaces"]["customer-support"],
            "title": "Refresh refund delay macro wording before spring sale launch",
            "description": "Update the customer-facing macro so it reflects the current refund SLA and references the payments queue status page.",
            "status": "in_progress",
            "priority": "high",
            "assignee": users["support_qa"],
            "created_by": users["moderator"],
            "source_kind": "incident",
            "source_id": refs["incidents"]["customer-support:refund-queue-delay"].id,
            "due_at": BASE_TS + timedelta(days=4),
            "created_at": ts(days_ago=2),
            "updated_at": ts(days_ago=0, hours=6),
        },
        {
            "key": "customer-support:qa-week-9",
            "space": refs["spaces"]["customer-support"],
            "title": "Audit escalation QA samples for week 9",
            "description": "Sample five escalations from the week 9 queue and score them against the new QA rubric before Friday coaching.",
            "status": "todo",
            "priority": "critical",
            "assignee": users["compliance"],
            "created_by": users["support_qa"],
            "source_kind": "sop",
            "source_id": refs["sops"]["customer-support:refund-delay-triage"].id,
            "due_at": BASE_TS + timedelta(days=1),
            "created_at": ts(days_ago=1, hours=10),
            "updated_at": ts(days_ago=1, hours=10),
        },
    ]

    refs["tasks"] = {}
    refs["task_comments"] = {}
    for spec in task_specs:
        task_id = seed_uuid("task", spec["key"])
        task = upsert_row(
            db,
            Task,
            pk_field="id",
            pk_value=task_id,
            space_id=spec["space"].id,
            title=spec["title"],
            description=spec["description"],
            status=spec["status"],
            priority=spec["priority"],
            assignee_user_id=spec["assignee"].id,
            created_by=spec["created_by"].id,
            source_kind=spec.get("source_kind"),
            source_id=spec.get("source_id"),
            source_step_id=spec.get("source_step_id"),
            due_at=spec["due_at"],
            created_at=spec["created_at"],
            updated_at=spec["updated_at"],
        )
        refs["tasks"][spec["key"]] = task

    db.flush()

    comment_specs = [
        (
            "platform-ops:analytics-query-guardrail",
            "thread-1",
            users["platform_lead"],
            "I have the SQL guardrail patch ready. I still need Samir's dashboard numbers before I can merge the rollout note.",
            ts(days_ago=1, hours=3),
            ts(days_ago=1, hours=2),
        ),
        (
            "platform-ops:analytics-query-guardrail",
            "thread-2",
            users["ops_analyst"],
            "Dashboard baseline is ready. I added p95 and DB CPU overlays so the release review can compare before and after.",
            ts(days_ago=1, hours=1),
            ts(days_ago=1, hours=1),
        ),
        (
            "store-ops:printer-asset-labels",
            "thread-1",
            users["member"],
            "Blocked on the replacement label stock. The new rolls arrive tomorrow morning with the Austin maintenance shipment.",
            ts(days_ago=0, hours=14),
            ts(days_ago=0, hours=14),
        ),
        (
            "customer-support:refund-macro-refresh",
            "thread-1",
            users["support_qa"],
            "Draft macro is in review. I aligned the wording with the refund SLA matrix and linked the status page in the agent note.",
            ts(days_ago=0, hours=8),
            ts(days_ago=0, hours=7),
        ),
        (
            "customer-support:qa-week-9",
            "thread-1",
            users["compliance"],
            "I need one more escalated billing case before I can finish the scoring spread. The current sample is too hardware-heavy.",
            ts(days_ago=0, hours=5),
            ts(days_ago=0, hours=5),
        ),
    ]
    for task_key, thread_key, author, body, created_at, updated_at in comment_specs:
        task = refs["tasks"][task_key]
        comment = upsert_row(
            db,
            TaskComment,
            pk_field="id",
            pk_value=seed_uuid("task-comment", task_key, thread_key),
            task_id=task.id,
            space_id=task.space_id,
            author_user_id=author.id,
            body=body,
            created_at=created_at,
            updated_at=updated_at,
        )
        refs["task_comments"][f"{task_key}:{thread_key}"] = comment

    db.flush()

    task_events = [
        (
            "task-create-1",
            ts(days_ago=4),
            "task_created",
            "platform-ops:analytics-query-guardrail",
            users["admin"],
        ),
        (
            "task-update-1",
            ts(days_ago=1, hours=4),
            "task_updated",
            "platform-ops:analytics-query-guardrail",
            users["platform_lead"],
        ),
        (
            "task-create-2",
            ts(days_ago=3, hours=4),
            "task_created",
            "store-ops:printer-asset-labels",
            users["retail_director"],
        ),
        (
            "task-update-2",
            ts(days_ago=0, hours=14),
            "task_updated",
            "store-ops:printer-asset-labels",
            users["member"],
        ),
        (
            "task-create-3",
            ts(days_ago=2),
            "task_created",
            "customer-support:refund-macro-refresh",
            users["moderator"],
        ),
        (
            "task-update-3",
            ts(days_ago=0, hours=6),
            "task_updated",
            "customer-support:refund-macro-refresh",
            users["support_qa"],
        ),
    ]
    for event_key, event_ts, event_type, task_key, actor in task_events:
        task = refs["tasks"][task_key]
        space = next(
            space for space in refs["spaces"].values() if space.id == task.space_id
        )
        upsert_event(
            db,
            event_id=seed_uuid("event", event_key),
            ts_value=event_ts,
            session_id=f"{event_key}-session",
            event_type=event_type,
            user=actor,
            space=space,
            entity_type="task",
            entity_id=task.id,
            path=f"/tasks?spaceId={space.id}",
            meta={"surface": "tasks", "seed": True, "task_title": task.title},
        )

    refs["task_execution_profiles"] = {}
    refs["task_reminder_dispatches"] = {}
    execution_profiles = [
        (
            "platform-ops:release-readiness-drill",
            refs["spaces"]["platform-ops"],
            refs["sops"]["platform-ops:rollback-api-release"],
            "Monthly rollback readiness drill",
            30,
            BASE_TS + timedelta(days=6),
            users["platform_lead"],
            True,
            ts(days_ago=24),
            "in_app,email",
            ts(days_ago=2),
            users["admin"],
            ts(days_ago=28),
        ),
        (
            "store-ops:printer-drill",
            refs["spaces"]["store-ops"],
            refs["sops"]["store-ops:replace-pos-receipt-printer"],
            "Austin hardware replacement practice",
            7,
            BASE_TS + timedelta(days=1),
            users["member"],
            True,
            ts(days_ago=6),
            "in_app,email",
            ts(days_ago=1, hours=3),
            users["retail_director"],
            ts(days_ago=21),
        ),
        (
            "customer-support:refund-watch",
            refs["spaces"]["customer-support"],
            refs["sops"]["customer-support:refund-delay-triage"],
            "Refund delay SLA watch",
            14,
            BASE_TS + timedelta(days=2),
            users["support_qa"],
            True,
            ts(days_ago=13),
            "in_app,webhook",
            ts(days_ago=0, hours=6),
            users["moderator"],
            ts(days_ago=19),
        ),
    ]
    for (
        profile_key,
        space,
        sop,
        title,
        cadence_days,
        next_due_at,
        operator,
        enabled,
        last_started_at,
        reminder_channels_csv,
        last_reminder_sent_at,
        created_by,
        created_at,
    ) in execution_profiles:
        profile = upsert_row(
            db,
            TaskExecutionProfile,
            pk_field="id",
            pk_value=seed_uuid("task-execution-profile", profile_key),
            space_id=space.id,
            source_kind="sop",
            source_id=sop.id,
            source_step_id=None,
            title=title,
            cadence_days=cadence_days,
            next_due_at=next_due_at,
            operator_user_id=operator.id,
            enabled=enabled,
            last_started_at=last_started_at,
            reminder_channels_csv=reminder_channels_csv,
            last_reminder_sent_at=last_reminder_sent_at,
            created_by=created_by.id,
            created_at=created_at,
            updated_at=ts(days_ago=0, hours=4),
        )
        refs["task_execution_profiles"][profile_key] = profile

    dispatch_rows = [
        (
            "store-ops:printer-drill",
            "email",
            users["member"],
            {
                "title": "Austin hardware replacement practice",
                "summary": "Printer replacement practice is due tomorrow for the Austin store pilot lanes.",
            },
            ts(days_ago=0, hours=9),
            ts(days_ago=0, hours=9),
        ),
        (
            "customer-support:refund-watch",
            "webhook",
            None,
            {
                "title": "Refund delay SLA watch",
                "summary": "Refund delay triage is due in 48 hours.",
                "target": "ops-automation",
            },
            ts(days_ago=0, hours=6),
            None,
        ),
        (
            "platform-ops:release-readiness-drill",
            "in_app",
            users["platform_lead"],
            {
                "title": "Monthly rollback readiness drill",
                "summary": "Rollback readiness drill is scheduled for next week.",
            },
            ts(days_ago=2),
            ts(days_ago=2),
        ),
    ]
    for (
        profile_key,
        channel,
        recipient,
        payload,
        created_at,
        delivered_at,
    ) in dispatch_rows:
        profile = refs["task_execution_profiles"][profile_key]
        dispatch = upsert_row(
            db,
            TaskReminderDispatch,
            pk_field="id",
            pk_value=seed_uuid("task-reminder-dispatch", profile_key, channel),
            profile_id=profile.id,
            space_id=profile.space_id,
            source_kind=profile.source_kind,
            source_id=profile.source_id,
            source_step_id=profile.source_step_id,
            recipient_user_id=None if recipient is None else recipient.id,
            channel=channel,
            payload_json=json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
            created_at=created_at,
            delivered_at=delivered_at,
        )
        refs["task_reminder_dispatches"][f"{profile_key}:{channel}"] = dispatch


def seed_kb_enrichment(
    db: Session, users: dict[str, User], refs: dict[str, dict[str, Any]]
) -> None:
    kb_policies = {
        "platform-ops": (
            45,
            {"rollback": ["revert", "backout"], "latency": ["p95", "response time"]},
            ["release-train", "error-budget", "rollback-window"],
        ),
        "store-ops": (
            30,
            {
                "printer": ["receipt printer", "lane printer"],
                "inventory": ["cycle count", "stock check"],
            },
            ["cash-float", "lane-health", "inventory-sync"],
        ),
        "customer-support": (
            21,
            {
                "refund": ["reimbursement", "charge reversal"],
                "handoff": ["after-hours", "escalation"],
            },
            ["customer-trust", "billing-ops", "macro-library"],
        ),
    }
    for space_key, (retention_days, synonyms, lexicon) in kb_policies.items():
        space = refs["spaces"][space_key]
        upsert_row(
            db,
            KbSpacePolicy,
            pk_field="space_id",
            pk_value=space.id,
            trash_retention_days=retention_days,
            synonyms_json=json.dumps(synonyms, ensure_ascii=False),
            lexicon_json=json.dumps(lexicon, ensure_ascii=False),
            last_purge_run_at=ts(days_ago=2),
        )

    tag_map: dict[str, list[str]] = {
        "platform-ops:incident-commander-quickstart": [
            "incident-response",
            "war-room",
            "on-call",
        ],
        "platform-ops:api-release-checklist": ["release", "api", "production"],
        "platform-ops:postgres-restore-drill": ["database", "restore", "drill"],
        "platform-ops:service-dependency-map": [
            "architecture",
            "dependencies",
            "reliability",
        ],
        "platform-ops:new-engineer-week-1": ["onboarding", "engineering", "training"],
        "store-ops:store-opening-checklist": ["opening", "cash-handling", "frontline"],
        "store-ops:store-closing-cash-drop": ["closing", "cash-drop", "compliance"],
        "store-ops:pos-terminal-health-check": ["hardware", "pos", "diagnostics"],
        "store-ops:cycle-count-escalation-guide": ["inventory", "audit", "discrepancy"],
        "customer-support:tier1-escalation-routing": [
            "routing",
            "escalation",
            "triage",
        ],
        "customer-support:refund-eligibility-matrix": ["refund", "billing", "policy"],
        "customer-support:chat-macros-high-volume": ["macro", "chat", "queue-spike"],
        "customer-support:qa-escalation-review-rubric": ["qa", "coaching", "draft"],
    }
    for key, doc in refs["docs"].items():
        tags = tag_map.get(
            key, [segment for segment in doc.slug.split("-")[:3] if segment]
        )
        deleted_at = (
            ts(days_ago=1) if key == "store-ops:cycle-count-escalation-guide" else None
        )
        deleted_by = users["retail_director"].id if deleted_at else None
        last_reviewed_at = doc.updated_at if doc.status == "published" else None
        last_reviewed_by = (
            users["platform_lead"].id
            if key.startswith("platform-ops:")
            else users["retail_director"].id
            if key.startswith("store-ops:")
            else users["support_qa"].id
        )
        review_due_at = (
            (doc.updated_at + timedelta(days=30))
            if doc.status == "published"
            else (BASE_TS + timedelta(days=14))
        )
        upsert_row(
            db,
            DocMeta,
            pk_field="doc_id",
            pk_value=doc.id,
            tags_json=json.dumps(tags, ensure_ascii=False),
            deleted_at=deleted_at,
            deleted_by=deleted_by,
            review_due_at=review_due_at,
            last_reviewed_at=last_reviewed_at,
            last_reviewed_by=last_reviewed_by if last_reviewed_at else None,
        )

    for doc_key, reviewer_key, reminder_days in [
        ("platform-ops:api-release-checklist", "platform_lead", 2),
        ("store-ops:pos-terminal-health-check", "retail_director", 5),
        ("customer-support:refund-eligibility-matrix", "support_qa", 3),
    ]:
        doc = refs["docs"][doc_key]
        upsert_row(
            db,
            DocReviewAssignment,
            pk_field="doc_id",
            pk_value=doc.id,
            reviewer_user_id=users[reviewer_key].id,
            reminder_days=reminder_days,
        )

    comment_specs = [
        (
            "platform-ops:api-release-checklist",
            "release-note",
            users["platform_lead"],
            "Add a direct link to the rollback SOP in the post-deploy section so the incident commander does not need to search for it during a hot rollback.",
            ts(days_ago=1, hours=5),
            ts(days_ago=1, hours=4),
        ),
        (
            "customer-support:refund-eligibility-matrix",
            "macro-alignment",
            users["support_qa"],
            "The subscription dispute row is good. Please keep the processor settlement ID note because agents are finally using it correctly.",
            ts(days_ago=1, hours=2),
            ts(days_ago=1, hours=2),
        ),
        (
            "store-ops:store-opening-checklist",
            "opening-review",
            users["retail_director"],
            "We should call out the curbside pickup board sooner during holiday weeks so shift leads do not miss the handoff.",
            ts(days_ago=0, hours=18),
            ts(days_ago=0, hours=18),
        ),
    ]
    for doc_key, comment_key, actor, body_md, created_at, updated_at in comment_specs:
        doc = refs["docs"][doc_key]
        comment = upsert_row(
            db,
            DocComment,
            pk_field="id",
            pk_value=seed_uuid("doc-comment", doc_key, comment_key),
            doc_id=doc.id,
            user_id=actor.id,
            body_md=body_md,
            created_at=created_at,
            updated_at=updated_at,
        )
        refs.setdefault("doc_comments", {})[f"{doc_key}:{comment_key}"] = comment

    db.flush()

    mention_specs = [
        (
            "platform-ops:api-release-checklist",
            "release-note",
            users["admin"],
            ts(days_ago=1, hours=4),
            None,
        ),
        (
            "customer-support:refund-eligibility-matrix",
            "macro-alignment",
            users["moderator"],
            ts(days_ago=1, hours=2),
            ts(days_ago=1, hours=1),
        ),
    ]
    for doc_key, comment_key, recipient, created_at, read_at in mention_specs:
        doc = refs["docs"][doc_key]
        comment = refs["doc_comments"][f"{doc_key}:{comment_key}"]
        upsert_row(
            db,
            DocMentionNotification,
            pk_field="id",
            pk_value=seed_uuid("doc-mention", doc_key, comment_key, recipient.email),
            doc_id=doc.id,
            comment_id=comment.id,
            user_id=recipient.id,
            created_at=created_at,
            read_at=read_at,
        )


def seed_incident_enrichment(
    db: Session, users: dict[str, User], refs: dict[str, dict[str, Any]]
) -> None:
    if "store-ops:lane-4-printer-failure" not in refs["incidents"]:
        refs["incidents"]["store-ops:lane-4-printer-failure"] = get_or_create_incident(
            db,
            key="lane-4-printer-failure",
            space=refs["spaces"]["store-ops"],
            title="Lane 4 printer validation failure after replacement",
            status="open",
            severity=4,
            summary_md=md(
                [
                    "# Summary",
                    "",
                    "Austin store reported a repeated printer validation failure after a replacement swap on lane 4.",
                    "The lane is running with backup paper handling while the field team inspects the USB harness and printer head alignment.",
                ]
            ),
            created_by=users["member"],
            created_at=ts(days_ago=0, hours=14),
            timeline=[
                {
                    "ts": ts(days_ago=0, hours=14),
                    "entry_md": "Lane 4 resumed, but the printer self-test still failed after the swap.",
                    "created_by": users["member"],
                },
                {
                    "ts": ts(days_ago=0, hours=13),
                    "entry_md": "Escalated to field ops and opened follow-up for hardware inspection.",
                    "created_by": users["retail_director"],
                },
            ],
        )

    refs["incident_templates"] = {}
    template_specs = [
        {
            "key": "global-service-degradation",
            "space": None,
            "name": "Global Service Degradation",
            "incident_type": "service",
            "severity": 2,
            "title_template": "Major service degradation affecting {service_name}",
            "summary_template_md": md(
                [
                    "# Incident Summary",
                    "",
                    "- What is failing:",
                    "- Customer impact:",
                    "- Earliest known start time:",
                    "- Current mitigation:",
                ]
            ),
            "postmortem_template_md": md(
                [
                    "# Postmortem",
                    "",
                    "## Impact",
                    "",
                    "## Root Cause",
                    "",
                    "## Timeline",
                    "",
                    "## Corrective Actions",
                ]
            ),
            "default_impacts_json": [
                {
                    "service_name": "Customer API",
                    "impact_level": "degraded",
                    "blast_radius": "global",
                    "customer_facing": True,
                },
                {
                    "service_name": "Admin Workspace",
                    "impact_level": "risk",
                    "blast_radius": "global",
                    "customer_facing": False,
                },
            ],
            "created_by": users["admin"],
            "created_at": ts(days_ago=32),
            "updated_at": ts(days_ago=8),
        },
        {
            "key": "store-hardware-failure",
            "space": refs["spaces"]["store-ops"],
            "name": "Store Hardware Failure",
            "incident_type": "infra",
            "severity": 4,
            "title_template": "Store hardware issue on {store_name} lane {lane}",
            "summary_template_md": md(
                [
                    "# Store Incident Summary",
                    "",
                    "- Store / lane:",
                    "- Affected hardware:",
                    "- Workaround in use:",
                    "- Estimated next update:",
                ]
            ),
            "postmortem_template_md": md(
                [
                    "# Field Postmortem",
                    "",
                    "## Symptoms",
                    "",
                    "## Parts Replaced",
                    "",
                    "## Final Verification",
                    "",
                    "## Follow-up",
                ]
            ),
            "default_impacts_json": [
                {
                    "service_name": "Point of Sale",
                    "impact_level": "degraded",
                    "blast_radius": "single-service",
                    "customer_facing": True,
                },
            ],
            "created_by": users["retail_director"],
            "created_at": ts(days_ago=21),
            "updated_at": ts(days_ago=2),
        },
        {
            "key": "support-queue-delay",
            "space": refs["spaces"]["customer-support"],
            "name": "Support Queue Delay",
            "incident_type": "support",
            "severity": 3,
            "title_template": "Support queue delay in {queue_name}",
            "summary_template_md": md(
                [
                    "# Queue Delay Summary",
                    "",
                    "- Queue:",
                    "- Customer promise at risk:",
                    "- Known upstream dependency:",
                    "- Current customer messaging:",
                ]
            ),
            "postmortem_template_md": md(
                [
                    "# Support Postmortem",
                    "",
                    "## Trigger",
                    "",
                    "## Operational Impact",
                    "",
                    "## Customer Communication",
                    "",
                    "## Prevention",
                ]
            ),
            "default_impacts_json": [
                {
                    "service_name": "Refund Queue",
                    "impact_level": "degraded",
                    "blast_radius": "regional",
                    "customer_facing": True,
                },
                {
                    "service_name": "Agent Workflow",
                    "impact_level": "risk",
                    "blast_radius": "regional",
                    "customer_facing": False,
                },
            ],
            "created_by": users["support_qa"],
            "created_at": ts(days_ago=18),
            "updated_at": ts(days_ago=1),
        },
    ]
    for spec in template_specs:
        template = upsert_row(
            db,
            IncidentTemplate,
            pk_field="id",
            pk_value=seed_uuid("incident-template", spec["key"]),
            space_id=None if spec["space"] is None else spec["space"].id,
            name=spec["name"],
            incident_type=spec["incident_type"],
            severity=spec["severity"],
            title_template=spec["title_template"],
            summary_template_md=spec["summary_template_md"],
            postmortem_template_md=spec["postmortem_template_md"],
            default_impacts_json=json.dumps(
                spec["default_impacts_json"],
                ensure_ascii=False,
                separators=(",", ":"),
            ),
            active=True,
            created_by=spec["created_by"].id,
            created_at=spec["created_at"],
            updated_at=spec["updated_at"],
        )
        refs["incident_templates"][spec["key"]] = template

    db.flush()

    refs["incident_profiles"] = {}
    profile_specs = [
        (
            "platform-ops:latency-spike-after-release",
            "service",
            "global-service-degradation",
            "platform_lead",
            "sev1",
            "bridge_open",
            "Release train paused while the rollback verification window completed.",
            "Customer API latency affected all signed-in users in the shared cluster.",
            True,
            True,
            ts(days_ago=2, hours=10),
            ts(days_ago=0, hours=12),
        ),
        (
            "platform-ops:backup-proxy-timeouts",
            "infra",
            "global-service-degradation",
            "ops_analyst",
            "watch",
            "normal",
            "Issue is isolated to snapshot tree browsing and only during large preview requests.",
            "Admin backup browsing is degraded for large snapshots; customer-facing surfaces are not affected.",
            False,
            True,
            ts(days_ago=1, hours=6),
            ts(days_ago=0, hours=7),
        ),
        (
            "store-ops:pos-sync-backlog",
            "infra",
            "store-hardware-failure",
            "retail_director",
            "sev2",
            "handoff",
            "Regional retail vendor is coordinating the replay while stores use manual verification.",
            "Inventory accuracy is at risk across multiple EU stores until sync lag is cleared.",
            False,
            True,
            ts(days_ago=1, hours=12),
            ts(days_ago=0, hours=10),
        ),
        (
            "customer-support:refund-queue-delay",
            "support",
            "support-queue-delay",
            "support_qa",
            "sev2",
            "escalated",
            "Payments retry pressure was handled, but support leads requested clearer customer messaging.",
            "Refund confirmation delays affected EU and US queues during the gateway timeout window.",
            True,
            True,
            ts(days_ago=5, hours=8),
            ts(days_ago=0, hours=8),
        ),
        (
            "store-ops:lane-4-printer-failure",
            "infra",
            "store-hardware-failure",
            "member",
            "standard",
            "normal",
            "Field team is waiting for the replacement harness before closing the follow-up.",
            "Single Austin pilot lane is running on a backup flow while diagnostics continue.",
            False,
            True,
            ts(days_ago=0, hours=14),
            ts(days_ago=0, hours=5),
        ),
    ]
    for (
        incident_key,
        incident_type,
        template_key,
        on_call_key,
        escalation_policy,
        escalation_status,
        escalation_notes,
        blast_radius_summary,
        public_enabled,
        private_enabled,
        created_at,
        updated_at,
    ) in profile_specs:
        incident = refs["incidents"][incident_key]
        profile = upsert_row(
            db,
            IncidentProfile,
            pk_field="incident_id",
            pk_value=incident.id,
            archived=False,
            incident_type=incident_type,
            template_id=refs["incident_templates"][template_key].id,
            on_call_user_id=users[on_call_key].id,
            escalation_policy=escalation_policy,
            escalation_status=escalation_status,
            escalation_notes=escalation_notes,
            blast_radius_summary=blast_radius_summary,
            public_status_enabled=public_enabled,
            private_status_enabled=private_enabled,
            created_at=created_at,
            updated_at=updated_at,
        )
        refs["incident_profiles"][incident_key] = profile

    postmortems = {
        "platform-ops:latency-spike-after-release": md(
            [
                "# Postmortem",
                "",
                "The release introduced an unbounded analytics aggregate path that scanned too much recent event data.",
                "",
                "## What changed",
                "- Added a release checklist item for query guardrails",
                "- Opened follow-up tasks for canary metrics and dashboarding",
            ]
        ),
        "customer-support:refund-queue-delay": md(
            [
                "# Postmortem",
                "",
                "Timeouts from the payment gateway caused retries to stack faster than the worker pool could drain them.",
                "",
                "## Mitigation",
                "- Temporary concurrency increase",
                "- Updated support macro with honest timing guidance",
            ]
        ),
        "store-ops:lane-4-printer-failure": md(
            [
                "# Field Notes",
                "",
                "This is still open. Current working theory is a damaged cable harness rather than the replacement printer unit itself.",
            ]
        ),
    }
    for incident_key, postmortem_md in postmortems.items():
        incident = refs["incidents"][incident_key]
        upsert_row(
            db,
            IncidentMeta,
            pk_field="incident_id",
            pk_value=incident.id,
            postmortem_md=postmortem_md,
        )

    refs["incident_impacts"] = {}
    impact_specs = [
        (
            "platform-ops:latency-spike-after-release",
            "customer-api",
            "Customer API",
            "degraded",
            "global",
            True,
            "High latency on authenticated requests.",
            "platform_lead",
        ),
        (
            "platform-ops:latency-spike-after-release",
            "admin-workspace",
            "Admin Workspace",
            "risk",
            "global",
            False,
            "Internal dashboards lagged during the same query spike.",
            "admin",
        ),
        (
            "platform-ops:backup-proxy-timeouts",
            "backup-browser",
            "Backup Browser",
            "degraded",
            "single-service",
            False,
            "Large snapshot trees timed out while rendering.",
            "ops_analyst",
        ),
        (
            "store-ops:pos-sync-backlog",
            "inventory-sync",
            "Inventory Sync",
            "degraded",
            "regional",
            True,
            "Serialized inventory lagged in EU stores.",
            "retail_director",
        ),
        (
            "store-ops:pos-sync-backlog",
            "store-reporting",
            "Store Reporting",
            "risk",
            "regional",
            False,
            "Managers used manual spot checks until sync recovered.",
            "retail_director",
        ),
        (
            "customer-support:refund-queue-delay",
            "refund-queue",
            "Refund Queue",
            "degraded",
            "regional",
            True,
            "Refund confirmations were delayed beyond normal SLA.",
            "support_qa",
        ),
        (
            "customer-support:refund-queue-delay",
            "agent-workflow",
            "Agent Workflow",
            "risk",
            "regional",
            False,
            "Agents needed manual macros and extra case notes.",
            "moderator",
        ),
        (
            "store-ops:lane-4-printer-failure",
            "point-of-sale",
            "Point of Sale",
            "degraded",
            "single-service",
            True,
            "Lane 4 was placed on a slower manual receipt flow.",
            "member",
        ),
    ]
    for (
        incident_key,
        impact_key,
        service_name,
        impact_level,
        blast_radius,
        customer_facing,
        notes_md,
        created_by_key,
    ) in impact_specs:
        incident = refs["incidents"][incident_key]
        impact = upsert_row(
            db,
            IncidentImpactService,
            pk_field="id",
            pk_value=seed_uuid("incident-impact", incident_key, impact_key),
            incident_id=incident.id,
            service_name=service_name,
            impact_level=impact_level,
            blast_radius=blast_radius,
            customer_facing=customer_facing,
            notes_md=notes_md,
            created_by=users[created_by_key].id,
            created_at=ts(days_ago=1),
            updated_at=ts(days_ago=0, hours=8),
        )
        refs["incident_impacts"][f"{incident_key}:{impact_key}"] = impact

    timeline_categories: dict[str, list[tuple[str, bool]]] = {
        "platform-ops:latency-spike-after-release": [
            ("detection", True),
            ("coordination", False),
            ("diagnosis", False),
            ("mitigation", True),
            ("resolution", True),
        ],
        "platform-ops:backup-proxy-timeouts": [
            ("detection", False),
            ("diagnosis", False),
            ("monitoring", True),
        ],
        "store-ops:pos-sync-backlog": [
            ("detection", True),
            ("coordination", False),
            ("mitigation", False),
        ],
        "customer-support:refund-queue-delay": [
            ("detection", True),
            ("diagnosis", False),
            ("mitigation", False),
            ("resolution", True),
        ],
        "store-ops:lane-4-printer-failure": [
            ("detection", True),
            ("escalation", False),
        ],
    }
    for incident_key, entries in timeline_categories.items():
        incident = refs["incidents"][incident_key]
        rows = incident_timeline_rows(db, incident)
        for idx, row in enumerate(rows):
            category, pinned = entries[min(idx, len(entries) - 1)]
            upsert_row(
                db,
                IncidentTimelineMeta,
                pk_field="timeline_id",
                pk_value=row.id,
                category=category,
                pinned=pinned,
            )

    action_items = [
        (
            "platform-ops:latency-spike-after-release",
            "query-guardrail",
            "Add LIMIT and defensive pagination to analytics aggregation",
            users["platform_lead"],
            BASE_TS + timedelta(days=7),
            "done",
            "Merged with release notes and verified under production load test.",
            users["admin"],
            ts(days_ago=2),
            ts(days_ago=0, hours=12),
        ),
        (
            "platform-ops:latency-spike-after-release",
            "canary-gate",
            "Add canary gate for the analytics endpoint before full rollout",
            users["admin"],
            BASE_TS + timedelta(days=12),
            "open",
            "Waiting on dashboard baseline from ops analytics.",
            users["admin"],
            ts(days_ago=2),
            None,
        ),
        (
            "platform-ops:backup-proxy-timeouts",
            "tree-budget",
            "Define safe tree-size budget for backup browser previews",
            users["ops_analyst"],
            BASE_TS + timedelta(days=5),
            "open",
            "Needs two more QA sessions with large snapshot trees.",
            users["moderator"],
            ts(days_ago=1),
            None,
        ),
        (
            "store-ops:pos-sync-backlog",
            "vendor-replay",
            "Coordinate regional sync replay with the retail infrastructure vendor",
            users["retail_director"],
            BASE_TS + timedelta(days=2),
            "in_progress",
            "Vendor acknowledged and scheduled off-peak replay tonight.",
            users["member"],
            ts(days_ago=1),
            None,
        ),
        (
            "customer-support:refund-queue-delay",
            "gateway-alert",
            "Add payment gateway timeout alert to the support queue dashboard",
            users["support_qa"],
            BASE_TS + timedelta(days=4),
            "open",
            "Support leads want earlier warning before backlog appears in tickets.",
            users["moderator"],
            ts(days_ago=5),
            None,
        ),
        (
            "store-ops:lane-4-printer-failure",
            "cable-harness",
            "Replace the lane 4 USB cable harness and retest printer diagnostics",
            users["member"],
            BASE_TS + timedelta(days=1),
            "open",
            "Waiting for the replacement harness to arrive on the afternoon truck.",
            users["retail_director"],
            ts(days_ago=0, hours=13),
            None,
        ),
    ]
    for (
        incident_key,
        action_key,
        title,
        owner,
        due_at,
        status,
        notes_md,
        created_by,
        created_at,
        completed_at,
    ) in action_items:
        incident = refs["incidents"][incident_key]
        upsert_row(
            db,
            IncidentActionItem,
            pk_field="id",
            pk_value=seed_uuid("incident-action", incident_key, action_key),
            incident_id=incident.id,
            title=title,
            owner_user_id=owner.id,
            due_at=due_at,
            status=status,
            notes_md=notes_md,
            created_by=created_by.id,
            created_at=created_at,
            completed_at=completed_at,
        )

    db.flush()

    refs["incident_action_reminders"] = {}
    reminder_specs = [
        (
            "platform-ops:latency-spike-after-release",
            "canary-gate",
            "24h-follow-up",
            "in_app",
            "admin",
        ),
        (
            "platform-ops:backup-proxy-timeouts",
            "tree-budget",
            "next-business-day",
            "email",
            "ops_analyst",
        ),
        (
            "store-ops:pos-sync-backlog",
            "vendor-replay",
            "same-day-check",
            "in_app",
            "retail_director",
        ),
        (
            "customer-support:refund-queue-delay",
            "gateway-alert",
            "next-review",
            "email",
            "support_qa",
        ),
        (
            "store-ops:lane-4-printer-failure",
            "cable-harness",
            "arrival-check",
            "in_app",
            "member",
        ),
    ]
    for incident_key, action_key, reminder_key, channel, owner_key in reminder_specs:
        incident = refs["incidents"][incident_key]
        action_item_id = seed_uuid("incident-action", incident_key, action_key)
        action_item = db.get(IncidentActionItem, action_item_id)
        if action_item is None:
            continue
        reminder = upsert_row(
            db,
            IncidentActionReminder,
            pk_field="id",
            pk_value=seed_uuid(
                "incident-action-reminder",
                incident_key,
                action_key,
                reminder_key,
            ),
            incident_id=incident.id,
            action_item_id=action_item_id,
            owner_user_id=users[owner_key].id,
            reminder_key=reminder_key,
            channel=channel,
            due_at_snapshot=action_item.due_at,
            created_at=ts(days_ago=0, hours=4),
        )
        refs["incident_action_reminders"][
            f"{incident_key}:{action_key}:{reminder_key}"
        ] = reminder

    for incident_key, target_type, target_key, link_key, label, created_by in [
        (
            "platform-ops:latency-spike-after-release",
            "sop",
            "platform-ops:rollback-api-release",
            "rollback",
            "Rollback SOP",
            users["admin"],
        ),
        (
            "platform-ops:latency-spike-after-release",
            "doc",
            "platform-ops:api-release-checklist",
            "release-checklist",
            "API Release Checklist",
            users["admin"],
        ),
        (
            "customer-support:refund-queue-delay",
            "sop",
            "customer-support:refund-delay-triage",
            "refund-triage",
            "Refund Delay Triage SOP",
            users["moderator"],
        ),
        (
            "customer-support:refund-queue-delay",
            "doc",
            "customer-support:refund-eligibility-matrix",
            "refund-matrix",
            "Refund Eligibility Matrix",
            users["moderator"],
        ),
        (
            "store-ops:lane-4-printer-failure",
            "sop",
            "store-ops:replace-pos-receipt-printer",
            "printer-sop",
            "Replace POS Receipt Printer",
            users["retail_director"],
        ),
        (
            "store-ops:lane-4-printer-failure",
            "doc",
            "store-ops:pos-terminal-health-check",
            "printer-doc",
            "POS Terminal Daily Health Check",
            users["retail_director"],
        ),
    ]:
        incident = refs["incidents"][incident_key]
        target_id = refs[f"{target_type}s"][target_key].id
        upsert_row(
            db,
            IncidentLink,
            pk_field="id",
            pk_value=seed_uuid("incident-link", incident_key, link_key),
            incident_id=incident.id,
            target_type=target_type,
            target_id=target_id,
            label=label,
            created_by=created_by.id,
            created_at=ts(days_ago=1),
        )

    transition_specs = [
        (
            "platform-ops:latency-spike-after-release",
            "opened",
            None,
            "open",
            "Incident opened when p95 latency alert sustained above threshold.",
            users["viewer"],
            ts(days_ago=2, hours=10),
        ),
        (
            "platform-ops:latency-spike-after-release",
            "resolved",
            "open",
            "resolved",
            "Rollback completed and baseline metrics held steady for the observation window.",
            users["admin"],
            ts(days_ago=2, hours=9, minutes=5),
        ),
        (
            "platform-ops:backup-proxy-timeouts",
            "opened",
            None,
            "open",
            "QA observed timeouts in large snapshot tree browsing.",
            users["viewer"],
            ts(days_ago=1, hours=6),
        ),
        (
            "platform-ops:backup-proxy-timeouts",
            "monitoring",
            "open",
            "monitoring",
            "Mitigation in place while the team measures large-tree latency.",
            users["admin"],
            ts(days_ago=1, hours=5, minutes=10),
        ),
        (
            "store-ops:pos-sync-backlog",
            "opened",
            None,
            "open",
            "Regional sync lag detected across EU stores.",
            users["member"],
            ts(days_ago=1, hours=12),
        ),
        (
            "customer-support:refund-queue-delay",
            "opened",
            None,
            "open",
            "Refund confirmations started to miss expected turnaround windows.",
            users["viewer"],
            ts(days_ago=5, hours=8),
        ),
        (
            "customer-support:refund-queue-delay",
            "resolved",
            "open",
            "resolved",
            "Queue drained after worker concurrency increase and retry stabilization.",
            users["moderator"],
            ts(days_ago=5, hours=6, minutes=5),
        ),
        (
            "store-ops:lane-4-printer-failure",
            "opened",
            None,
            "open",
            "Opened after the replacement printer still failed its self-test.",
            users["retail_director"],
            ts(days_ago=0, hours=13),
        ),
    ]
    for (
        incident_key,
        transition_key,
        from_status,
        to_status,
        note_md,
        actor,
        changed_at,
    ) in transition_specs:
        incident = refs["incidents"][incident_key]
        upsert_row(
            db,
            IncidentStatusTransition,
            pk_field="id",
            pk_value=seed_uuid("incident-transition", incident_key, transition_key),
            incident_id=incident.id,
            from_status=from_status,
            to_status=to_status,
            note_md=note_md,
            changed_by=actor.id,
            changed_at=changed_at,
        )

    refs["incident_status_updates"] = {}
    status_updates = [
        (
            "platform-ops:latency-spike-after-release",
            "public-investigating",
            "public",
            "Investigating",
            "We are investigating elevated API latency affecting sign-in and saved workspace views.",
            "viewer",
            ts(days_ago=2, hours=10),
        ),
        (
            "platform-ops:latency-spike-after-release",
            "private-diagnosis",
            "private",
            "Diagnosis",
            "DB CPU spike is tied to the newly released analytics aggregation path. Rollback is approved.",
            "platform_lead",
            ts(days_ago=2, hours=9, minutes=35),
        ),
        (
            "platform-ops:latency-spike-after-release",
            "public-resolved",
            "public",
            "Resolved",
            "Rollback completed successfully and latency returned to baseline after the validation window.",
            "admin",
            ts(days_ago=2, hours=9, minutes=5),
        ),
        (
            "platform-ops:backup-proxy-timeouts",
            "private-monitoring",
            "private",
            "Monitoring",
            "Mitigation is in place for large snapshot previews while QA captures more traces.",
            "ops_analyst",
            ts(days_ago=1, hours=5),
        ),
        (
            "store-ops:pos-sync-backlog",
            "private-coordination",
            "private",
            "Coordination",
            "Regional stores were told to verify serialized inventory manually until the replay completes.",
            "retail_director",
            ts(days_ago=1, hours=10),
        ),
        (
            "customer-support:refund-queue-delay",
            "public-investigating",
            "public",
            "Investigating",
            "Refund confirmations are delayed for a subset of payment methods. Agents are sharing updated ETA guidance.",
            "viewer",
            ts(days_ago=5, hours=8),
        ),
        (
            "customer-support:refund-queue-delay",
            "private-mitigation",
            "private",
            "Mitigated",
            "Worker concurrency was raised and the macro update is now with support QA for final wording.",
            "support_qa",
            ts(days_ago=5, hours=7),
        ),
        (
            "customer-support:refund-queue-delay",
            "public-closed",
            "public",
            "Closed",
            "Refund queue latency recovered and confirmation times are back within normal SLA.",
            "moderator",
            ts(days_ago=5, hours=6),
        ),
        (
            "store-ops:lane-4-printer-failure",
            "private-handoff",
            "private",
            "Awaiting Parts",
            "Replacement harness is expected on the afternoon truck. Lane remains open with manual receipt fallback.",
            "member",
            ts(days_ago=0, hours=12),
        ),
    ]
    for (
        incident_key,
        update_key,
        stream_type,
        status,
        message_md,
        actor_key,
        created_at,
    ) in status_updates:
        incident = refs["incidents"][incident_key]
        row = upsert_row(
            db,
            IncidentStatusUpdate,
            pk_field="id",
            pk_value=seed_uuid("incident-status-update", incident_key, update_key),
            incident_id=incident.id,
            stream_type=stream_type,
            status=status,
            message_md=message_md,
            created_by=users[actor_key].id,
            created_at=created_at,
        )
        refs["incident_status_updates"][f"{incident_key}:{update_key}"] = row


def seed_sop_enrichment(
    db: Session, users: dict[str, User], refs: dict[str, dict[str, Any]]
) -> None:
    step_maps = {key: sop_steps_by_order(db, sop) for key, sop in refs["sops"].items()}

    sop_meta_rows = [
        (
            "platform-ops:rollback-api-release",
            BASE_TS + timedelta(days=14),
            ts(days_ago=5),
            users["platform_lead"],
            True,
            ts(days_ago=4),
            users["admin"],
            None,
            None,
        ),
        (
            "platform-ops:rotate-db-credentials",
            BASE_TS + timedelta(days=7),
            ts(days_ago=35),
            users["platform_lead"],
            True,
            None,
            None,
            None,
            None,
        ),
        (
            "store-ops:replace-pos-receipt-printer",
            BASE_TS + timedelta(days=30),
            ts(days_ago=7),
            users["retail_director"],
            False,
            None,
            None,
            None,
            None,
        ),
        (
            "store-ops:inventory-recount-escalation",
            BASE_TS + timedelta(days=20),
            ts(days_ago=9),
            users["retail_director"],
            False,
            None,
            None,
            None,
            None,
        ),
        (
            "customer-support:after-hours-handoff",
            BASE_TS + timedelta(days=21),
            ts(days_ago=4),
            users["support_qa"],
            False,
            None,
            None,
            None,
            None,
        ),
        (
            "customer-support:refund-delay-triage",
            BASE_TS + timedelta(days=18),
            ts(days_ago=3),
            users["support_qa"],
            True,
            ts(days_ago=2),
            users["moderator"],
            None,
            None,
        ),
    ]
    for (
        sop_key,
        review_due_at,
        last_reviewed_at,
        reviewer,
        requires_approval,
        approved_at,
        approved_by,
        archived_at,
        archived_by,
    ) in sop_meta_rows:
        sop = refs["sops"][sop_key]
        upsert_row(
            db,
            SopMeta,
            pk_field="sop_id",
            pk_value=sop.id,
            review_due_at=review_due_at,
            last_reviewed_at=last_reviewed_at,
            reviewer_user_id=reviewer.id,
            requires_approval=requires_approval,
            approved_at=approved_at,
            approved_by=None if approved_by is None else approved_by.id,
            archived_at=archived_at,
            archived_by=None if archived_by is None else archived_by.id,
        )

    evidence_steps = [
        (
            "platform-ops:rollback-api-release",
            4,
            1,
            "png,jpg,pdf",
            2,
            users["platform_lead"],
            "Rollback smoke test evidence failed for {sop_title}",
        ),
        (
            "store-ops:replace-pos-receipt-printer",
            4,
            1,
            "jpg,png,pdf",
            3,
            users["retail_director"],
            "Printer validation failed after replacement in {sop_title}",
        ),
        (
            "customer-support:refund-delay-triage",
            4,
            1,
            "png,pdf",
            2,
            users["support_qa"],
            "Refund escalation evidence incomplete for {sop_title}",
        ),
    ]
    for (
        sop_key,
        step_order,
        min_file_count,
        allowed_csv,
        follow_up_severity,
        follow_up_owner,
        follow_up_title,
    ) in evidence_steps:
        step = step_maps[sop_key][step_order]
        upsert_row(
            db,
            SopStepMeta,
            pk_field="step_id",
            pk_value=step.id,
            requires_evidence=True,
        )
        upsert_row(
            db,
            SopStepEvidenceRule,
            pk_field="step_id",
            pk_value=step.id,
            min_file_count=min_file_count,
            allowed_extensions_csv=allowed_csv,
            follow_up_severity=follow_up_severity,
            follow_up_owner_user_id=follow_up_owner.id,
            follow_up_title_template=follow_up_title,
        )

    stage_rows = [
        (
            "platform-ops:rollback-api-release",
            1,
            users["platform_lead"],
            "Platform Lead Approval",
            None,
            None,
            None,
        ),
        (
            "platform-ops:rollback-api-release",
            2,
            users["admin"],
            "Operations Change Approval",
            None,
            None,
            None,
        ),
        (
            "platform-ops:rotate-db-credentials",
            1,
            users["admin"],
            "Security Change Approval",
            users["moderator"],
            ts(days_ago=1),
            BASE_TS + timedelta(days=7),
        ),
        (
            "customer-support:refund-delay-triage",
            1,
            users["moderator"],
            "Support Lead Approval",
            None,
            None,
            None,
        ),
    ]
    stage_ids: dict[tuple[str, int], str] = {}
    for (
        sop_key,
        stage_order,
        approver,
        label,
        delegate,
        delegate_start_at,
        delegate_end_at,
    ) in stage_rows:
        sop = refs["sops"][sop_key]
        stage_id = seed_uuid("sop-approval-stage", sop_key, str(stage_order))
        stage_ids[(sop_key, stage_order)] = stage_id
        upsert_row(
            db,
            SopApprovalStage,
            pk_field="id",
            pk_value=stage_id,
            sop_id=sop.id,
            stage_order=stage_order,
            approver_user_id=approver.id,
            label=label,
            delegate_approver_user_id=None if delegate is None else delegate.id,
            delegate_start_at=delegate_start_at,
            delegate_end_at=delegate_end_at,
        )

    db.flush()

    decision_rows = [
        (
            "platform-ops:rollback-api-release",
            1,
            "approve",
            users["platform_lead"],
            "Reviewed rollback steps and confirmed the smoke-test evidence requirement.",
            ts(days_ago=4, hours=12),
        ),
        (
            "platform-ops:rollback-api-release",
            2,
            "approve",
            users["admin"],
            "Approved for production rollback use after postmortem updates were added.",
            ts(days_ago=4, hours=10),
        ),
        (
            "platform-ops:rotate-db-credentials",
            1,
            "change_request",
            users["admin"],
            "Add an explicit verification query list before this can be published.",
            ts(days_ago=1, hours=6),
        ),
        (
            "customer-support:refund-delay-triage",
            1,
            "approve",
            users["moderator"],
            "Approved after aligning the SLA wording with billing policy.",
            ts(days_ago=2, hours=3),
        ),
    ]
    for (
        sop_key,
        stage_order,
        decision_type,
        actor,
        note_md,
        approved_at,
    ) in decision_rows:
        sop = refs["sops"][sop_key]
        upsert_row(
            db,
            SopApprovalDecision,
            pk_field="id",
            pk_value=seed_uuid(
                "sop-approval-decision", sop_key, str(stage_order), decision_type
            ),
            sop_id=sop.id,
            stage_id=stage_ids[(sop_key, stage_order)],
            approved_by=actor.id,
            approved_at=approved_at,
            decision_type=decision_type,
            note_md=note_md,
        )

    run_specs = [
        (
            "platform-ops:rollback-api-release",
            "release-rollback-drill",
            "completed",
            users["moderator"],
            ts(days_ago=1, hours=6),
            ts(days_ago=1, hours=5),
        ),
        (
            "store-ops:replace-pos-receipt-printer",
            "austin-printer-swap",
            "in_progress",
            users["member"],
            ts(days_ago=0, hours=14),
            None,
        ),
        (
            "customer-support:refund-delay-triage",
            "refund-delay-check",
            "completed",
            users["support_qa"],
            ts(days_ago=0, hours=9),
            ts(days_ago=0, hours=8),
        ),
    ]
    refs["sop_runs"] = {}
    refs["sop_run_steps"] = {}
    for sop_key, run_key, status, started_by, started_at, completed_at in run_specs:
        sop = refs["sops"][sop_key]
        run = upsert_row(
            db,
            SopRun,
            pk_field="id",
            pk_value=seed_uuid("sop-run", sop_key, run_key),
            sop_id=sop.id,
            status=status,
            started_by=started_by.id,
            started_at=started_at,
            completed_at=completed_at,
        )
        refs["sop_runs"][f"{sop_key}:{run_key}"] = run

    db.flush()

    run_step_states = {
        "platform-ops:rollback-api-release:release-rollback-drill": {
            1: (
                True,
                users["moderator"],
                "Rollback criteria matched p95 and 5xx thresholds.",
                0,
                "",
            ),
            2: (
                True,
                users["moderator"],
                "Release queue was frozen in #ops-release.",
                0,
                "",
            ),
            3: (
                True,
                users["moderator"],
                "Previous image deployed from the last known good tag.",
                0,
                "",
            ),
            4: (
                True,
                users["moderator"],
                "Smoke test evidence captured from /health and login flow.",
                1,
                "png,jpg,pdf",
            ),
            5: (
                True,
                users["moderator"],
                "Metrics stabilized after 15 minutes.",
                0,
                "",
            ),
            6: (
                True,
                users["moderator"],
                "Incident updated with rollback context and follow-up tasks.",
                0,
                "",
            ),
        },
        "store-ops:replace-pos-receipt-printer:austin-printer-swap": {
            1: (
                True,
                users["member"],
                "Lane was paused and customers moved to adjacent register.",
                0,
                "",
            ),
            2: (
                True,
                users["member"],
                "Terminal ID and lane number captured in maintenance log.",
                0,
                "",
            ),
            3: (
                True,
                users["member"],
                "Printer swapped, but self-test still failing.",
                0,
                "",
            ),
            4: (False, None, "", 1, "jpg,png,pdf"),
            5: (False, None, "", 0, ""),
        },
        "customer-support:refund-delay-triage:refund-delay-check": {
            1: (
                True,
                users["support_qa"],
                "Approval timestamp verified in the queue.",
                0,
                "",
            ),
            2: (
                True,
                users["support_qa"],
                "Processor status confirmed as delayed but not failed.",
                0,
                "",
            ),
            3: (
                True,
                users["support_qa"],
                "Payment method was ACH, which explained the slower posting window.",
                0,
                "",
            ),
            4: (
                True,
                users["support_qa"],
                "Escalation note captured with payment references.",
                1,
                "png,pdf",
            ),
        },
    }
    for run_key, step_state in run_step_states.items():
        sop_key = ":".join(run_key.split(":")[:2])
        run = refs["sop_runs"][run_key]
        for step_order, step in step_maps[sop_key].items():
            completed, completed_by, evidence_note, min_files, allowed_csv = (
                step_state.get(
                    step_order,
                    (False, None, "", 0, ""),
                )
            )
            run_step = upsert_row(
                db,
                SopRunStep,
                pk_field="id",
                pk_value=seed_uuid("sop-run-step", run.id, str(step_order)),
                run_id=run.id,
                step_id=step.id,
                step_order=step.step_order,
                title=step.title,
                evidence_required=(step_order in step_state and min_files > 0),
                completed=completed,
                completed_at=(run.started_at + timedelta(minutes=step_order * 4))
                if completed
                else None,
                completed_by=None if completed_by is None else completed_by.id,
                evidence_note=evidence_note,
                evidence_min_files=min_files,
                evidence_allowed_extensions_csv=allowed_csv,
            )
            refs["sop_run_steps"][f"{run_key}:{step_order}"] = run_step

    db.flush()

    schedule_rows = [
        (
            "store-ops:replace-pos-receipt-printer",
            "austin-printer-recurring",
            7,
            BASE_TS + timedelta(days=1),
            users["member"],
            True,
            ts(days_ago=7),
            "in_app,email",
            ts(days_ago=1, hours=3),
        ),
        (
            "customer-support:refund-delay-triage",
            "refund-sla-watch",
            14,
            BASE_TS + timedelta(days=2),
            users["support_qa"],
            True,
            ts(days_ago=14),
            "in_app,webhook",
            ts(days_ago=0, hours=6),
        ),
    ]
    refs["sop_run_schedules"] = {}
    for (
        sop_key,
        schedule_key,
        cadence_days,
        next_due_at,
        operator,
        enabled,
        last_started_at,
        channels_csv,
        last_reminder,
    ) in schedule_rows:
        sop = refs["sops"][sop_key]
        schedule = upsert_row(
            db,
            SopRunSchedule,
            pk_field="id",
            pk_value=seed_uuid("sop-run-schedule", sop_key, schedule_key),
            sop_id=sop.id,
            cadence_days=cadence_days,
            next_due_at=next_due_at,
            operator_user_id=operator.id,
            enabled=enabled,
            last_started_at=last_started_at,
            reminder_channels_csv=channels_csv,
            last_reminder_sent_at=last_reminder,
        )
        refs["sop_run_schedules"][f"{sop_key}:{schedule_key}"] = schedule

    db.flush()

    dispatch_rows = [
        (
            "store-ops:replace-pos-receipt-printer",
            "austin-printer-recurring",
            "email",
            users["member"],
            {"summary": "Printer replacement drill is due tomorrow for Austin."},
            ts(days_ago=0, hours=9),
            ts(days_ago=0, hours=9),
        ),
        (
            "customer-support:refund-delay-triage",
            "refund-sla-watch",
            "webhook",
            None,
            {
                "summary": "Refund delay triage schedule is due in 48 hours.",
                "target": "ops-automation",
            },
            ts(days_ago=0, hours=6),
            None,
        ),
    ]
    for (
        sop_key,
        schedule_key,
        channel,
        recipient,
        payload,
        created_at,
        delivered_at,
    ) in dispatch_rows:
        sop = refs["sops"][sop_key]
        schedule = refs["sop_run_schedules"][f"{sop_key}:{schedule_key}"]
        upsert_row(
            db,
            SopReminderDispatch,
            pk_field="id",
            pk_value=seed_uuid("sop-reminder-dispatch", sop_key, schedule_key, channel),
            sop_id=sop.id,
            schedule_id=schedule.id,
            recipient_user_id=None if recipient is None else recipient.id,
            channel=channel,
            payload_json=json.dumps(payload, ensure_ascii=False),
            created_at=created_at,
            delivered_at=delivered_at,
        )

    printer_follow_up_step = refs["sop_run_steps"][
        "store-ops:replace-pos-receipt-printer:austin-printer-swap:4"
    ]
    upsert_row(
        db,
        SopRunFollowUp,
        pk_field="id",
        pk_value=seed_uuid("sop-run-follow-up", printer_follow_up_step.id),
        run_step_id=printer_follow_up_step.id,
        incident_id=refs["incidents"]["store-ops:lane-4-printer-failure"].id,
        created_by=users["retail_director"].id,
        created_at=ts(days_ago=0, hours=13),
    )


def seed_media_demo(
    db: Session, users: dict[str, User], refs: dict[str, dict[str, Any]]
) -> None:
    refs["media"] = {}
    logo_svg = (
        "<svg xmlns='http://www.w3.org/2000/svg' width='320' height='96' viewBox='0 0 320 96'>"
        "<rect width='320' height='96' rx='18' fill='#0B141F'/>"
        "<circle cx='46' cy='48' r='22' fill='#1D9BF0'/>"
        "<text x='82' y='57' font-family='Verdana' font-size='28' fill='#F5FAFF'>OpsAtlas</text>"
        "</svg>"
    ).encode("utf-8")
    favicon_svg = (
        "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32' viewBox='0 0 32 32'>"
        "<rect width='32' height='32' rx='8' fill='#08131F'/>"
        "<circle cx='16' cy='16' r='8' fill='#1D9BF0'/>"
        "</svg>"
    ).encode("utf-8")
    pdf_bytes = (
        b"%PDF-1.1\n1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj\n"
        b"2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj\n"
        b"3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>endobj\n"
        b"trailer<< /Root 1 0 R >>\n%%EOF"
    )
    text_bytes = (
        b"Customer support macro revision notes:\n"
        b"- Updated refund SLA wording\n"
        b"- Added payment status page reference\n"
    )

    primary_logo = upsert_media_asset(
        db,
        asset_id=seed_uuid("media-asset", "branding-primary-logo"),
        owner=users["admin"],
        space=None,
        usage="branding_logo",
        original_filename="opsatlas-wordmark.svg",
        content_type="image/svg+xml",
        storage_key="seed/branding/opsatlas-wordmark.svg",
        content=logo_svg,
        created_at=ts(days_ago=20),
    )
    favicon = upsert_media_asset(
        db,
        asset_id=seed_uuid("media-asset", "branding-favicon"),
        owner=users["admin"],
        space=None,
        usage="branding_favicon",
        original_filename="opsatlas-favicon.svg",
        content_type="image/svg+xml",
        storage_key="seed/branding/opsatlas-favicon.svg",
        content=favicon_svg,
        created_at=ts(days_ago=20),
    )
    rollback_evidence = upsert_media_asset(
        db,
        asset_id=seed_uuid("media-asset", "rollback-evidence"),
        owner=users["platform_lead"],
        space=refs["spaces"]["platform-ops"],
        usage="sop_attachment",
        original_filename="rollback-smoke-test-evidence.pdf",
        content_type="application/pdf",
        storage_key="seed/platform-ops/rollback-smoke-test-evidence.pdf",
        content=pdf_bytes,
        created_at=ts(days_ago=1, hours=5),
    )
    support_notes = upsert_media_asset(
        db,
        asset_id=seed_uuid("media-asset", "refund-macro-notes"),
        owner=users["support_qa"],
        space=refs["spaces"]["customer-support"],
        usage="task_comment_attachment",
        original_filename="refund-macro-notes.txt",
        content_type="text/plain",
        storage_key="seed/customer-support/refund-macro-notes.txt",
        content=text_bytes,
        created_at=ts(days_ago=0, hours=7),
    )
    refs["media"].update(
        {
            "branding-primary-logo": primary_logo,
            "branding-favicon": favicon,
            "rollback-evidence": rollback_evidence,
            "refund-macro-notes": support_notes,
        }
    )

    db.flush()

    upsert_row(
        db,
        MediaAssetMeta,
        pk_field="asset_id",
        pk_value=primary_logo.id,
        access_mode="public",
        folder_path="branding",
        tags_json=json.dumps(["branding", "logo", "default"], ensure_ascii=False),
        retention_days=None,
        created_at=ts(days_ago=20),
        updated_at=ts(days_ago=2),
    )
    upsert_row(
        db,
        MediaAssetMeta,
        pk_field="asset_id",
        pk_value=favicon.id,
        access_mode="public",
        folder_path="branding",
        tags_json=json.dumps(["branding", "favicon"], ensure_ascii=False),
        retention_days=None,
        created_at=ts(days_ago=20),
        updated_at=ts(days_ago=2),
    )
    upsert_row(
        db,
        MediaAssetMeta,
        pk_field="asset_id",
        pk_value=rollback_evidence.id,
        access_mode="space",
        folder_path="platform-ops/evidence",
        tags_json=json.dumps(
            ["rollback", "smoke-test", "evidence"], ensure_ascii=False
        ),
        retention_days=365,
        created_at=ts(days_ago=1, hours=5),
        updated_at=ts(days_ago=1, hours=4),
    )
    upsert_row(
        db,
        MediaAssetMeta,
        pk_field="asset_id",
        pk_value=support_notes.id,
        access_mode="space",
        folder_path="customer-support/macros",
        tags_json=json.dumps(["macro", "refund", "notes"], ensure_ascii=False),
        retention_days=180,
        created_at=ts(days_ago=0, hours=7),
        updated_at=ts(days_ago=0, hours=7),
    )

    settings_row = upsert_row(
        db,
        BrandingSettings,
        pk_field="id",
        pk_value=1,
        company_name="OpsAtlas Operations Cloud",
        application_title="OpsAtlas",
        application_short_name="OpsAtlas",
        web_description="Self-hosted operations workspace for procedures, incidents, knowledge, and follow-up work.",
        apple_web_app_title="OpsAtlas",
        logo_url=f"/media/{primary_logo.id}/file",
        light_logo_url=f"/media/{primary_logo.id}/file",
        dark_logo_url=f"/media/{primary_logo.id}/file",
        favicon_url=f"/media/{favicon.id}/file",
        light_seed_hex="#0F6CBD",
        dark_accent_hex="#1D9BF0",
        dark_bg_hex="#0B141F",
        browser_theme_hex="#0F6CBD",
        install_background_hex="#0A0D12",
        updated_at=ts(days_ago=0, hours=6),
    )
    settings_row.logo_url = f"/media/{primary_logo.id}/file"

    printer_run_step = refs["sop_run_steps"][
        "store-ops:replace-pos-receipt-printer:austin-printer-swap:4"
    ]
    macro_comment = refs["task_comments"][
        "customer-support:refund-macro-refresh:thread-1"
    ]
    upsert_row(
        db,
        MediaAttachment,
        pk_field="id",
        pk_value=seed_uuid(
            "media-attachment", rollback_evidence.id, printer_run_step.id
        ),
        asset_id=rollback_evidence.id,
        space_id=refs["spaces"]["platform-ops"].id,
        entity_type="sop_run_step",
        entity_id=printer_run_step.id,
        attached_by=users["platform_lead"].id,
        created_at=ts(days_ago=1, hours=5),
    )
    upsert_row(
        db,
        MediaAttachment,
        pk_field="id",
        pk_value=seed_uuid("media-attachment", support_notes.id, macro_comment.id),
        asset_id=support_notes.id,
        space_id=refs["spaces"]["customer-support"].id,
        entity_type="task_comment",
        entity_id=macro_comment.id,
        attached_by=users["support_qa"].id,
        created_at=ts(days_ago=0, hours=7),
    )

    usage_specs = [
        (
            primary_logo,
            None,
            "branding",
            "branding-settings",
            "primary_logo",
            ts(days_ago=0, hours=6),
        ),
        (favicon, None, "branding", "ops-night", "favicon", ts(days_ago=0, hours=6)),
        (
            rollback_evidence,
            refs["spaces"]["platform-ops"],
            "sop_run_step",
            printer_run_step.id,
            "evidence",
            ts(days_ago=1, hours=5),
        ),
        (
            support_notes,
            refs["spaces"]["customer-support"],
            "task_comment",
            macro_comment.id,
            "attachment",
            ts(days_ago=0, hours=7),
        ),
    ]
    for asset, space, entity_type, entity_id, field_name, updated_at in usage_specs:
        upsert_row(
            db,
            MediaUsage,
            pk_field="id",
            pk_value=seed_uuid(
                "media-usage", asset.id, entity_type, entity_id, field_name
            ),
            asset_id=asset.id,
            space_id=None if space is None else space.id,
            entity_type=entity_type,
            entity_id=entity_id,
            field_name=field_name,
            created_at=updated_at,
            updated_at=updated_at,
        )


def seed_branding_history(
    db: Session, users: dict[str, User], refs: dict[str, dict[str, Any]]
) -> None:
    primary_logo = refs["media"]["branding-primary-logo"]
    favicon = refs["media"]["branding-favicon"]
    draft_snapshot = _branding_snapshot(
        company_name="OpsAtlas Operations Cloud",
        application_title="OpsAtlas",
        application_short_name="OpsAtlas",
        web_description="Unified workspace for operational knowledge, incidents, SOP execution, and follow-up work.",
        apple_web_app_title="OpsAtlas",
        logo_url=f"/media/{primary_logo.id}/file",
        light_logo_url=f"/media/{primary_logo.id}/file",
        dark_logo_url=f"/media/{primary_logo.id}/file",
        favicon_url=f"/media/{favicon.id}/file",
        login_background_url=None,
        light_seed_hex="#0F6CBD",
        dark_accent_hex="#1D9BF0",
        dark_bg_hex="#0B141F",
        browser_theme_hex="#0F67E8",
        install_background_hex="#0A0D12",
    )
    live_snapshot = {
        **draft_snapshot,
        "web_description": "Self-hosted operations workspace for procedures, incidents, knowledge, and follow-up work.",
        "browser_theme_hex": "#0F6CBD",
    }

    upsert_row(
        db,
        BrandingDraft,
        pk_field="id",
        pk_value=1,
        snapshot_json=json.dumps(
            draft_snapshot, ensure_ascii=False, separators=(",", ":")
        ),
        created_at=ts(days_ago=8),
        updated_at=ts(days_ago=0, hours=6),
    )

    upsert_row(
        db,
        BrandingRevision,
        pk_field="id",
        pk_value=seed_uuid("branding-revision", "1"),
        revision_number=1,
        source_kind="seed",
        source_revision_id=None,
        summary="Seeded live branding for OpsAtlas",
        snapshot_json=json.dumps(
            draft_snapshot, ensure_ascii=False, separators=(",", ":")
        ),
        published_by_user_id=users["admin"].id,
        published_at=ts(days_ago=20),
        created_at=ts(days_ago=20),
    )
    upsert_row(
        db,
        BrandingRevision,
        pk_field="id",
        pk_value=seed_uuid("branding-revision", "2"),
        revision_number=2,
        source_kind="publish",
        source_revision_id=seed_uuid("branding-revision", "1"),
        summary="Published branding for OpsAtlas",
        snapshot_json=json.dumps(
            live_snapshot, ensure_ascii=False, separators=(",", ":")
        ),
        published_by_user_id=users["admin"].id,
        published_at=ts(days_ago=6),
        created_at=ts(days_ago=6),
    )


def seed_extended_records(
    db: Session, users: dict[str, User], refs: dict[str, dict[str, Any]]
) -> None:
    seed_extended_org_and_access(db, users, refs)
    seed_auth_runtime_demo(db, users, refs)
    seed_tasks_and_activity(db, users, refs)
    seed_kb_enrichment(db, users, refs)
    seed_incident_enrichment(db, users, refs)
    seed_sop_enrichment(db, users, refs)
    seed_media_demo(db, users, refs)
    seed_branding_history(db, users, refs)


def seed_localization_data(
    db: Session,
    users: dict[str, User],
) -> None:
    admin_user_id = users["admin"].id

    localization_service.update_catalog(
        db,
        default_language_code="en",
        organization_fallback_order=["en"],
        languages=[
            {
                "code": "en",
                "name": "English",
                "enabled": True,
                "is_default": True,
                "is_rtl": False,
                "fallback_order": ["en"],
            },
            {
                "code": "tr",
                "name": "Turkish",
                "enabled": True,
                "is_default": False,
                "is_rtl": False,
                "fallback_order": ["tr", "en"],
            },
            {
                "code": "de",
                "name": "German",
                "enabled": True,
                "is_default": False,
                "is_rtl": False,
                "fallback_order": ["de", "en"],
            },
        ],
        actor_user_id=admin_user_id,
    )

    localization_service.import_bundles(
        db,
        format_name="arb",
        bundles=_seed_bundle_payload(),
        dry_run=False,
        actor_user_id=admin_user_id,
    )

    upsert_row(
        db,
        LocalizationTranslationSetting,
        pk_field="id",
        pk_value=1,
        translation_enabled=True,
        provider="openai",
        model="gpt-5-mini",
        api_base_url="https://api.openai.com/v1",
        auto_translate_on_write=True,
        auto_approve=False,
        auto_retranslate_on_bundle_change=False,
        fallback_to_source=True,
        queue_max_attempts=4,
        queue_backoff_seconds=30,
        queue_batch_size=20,
        glossary_json="{}",
        translation_prompt=None,
        provider_options_json="{}",
        updated_by_user_id=admin_user_id,
    )

    sorted_users = sorted(
        users.values(), key=lambda row: (row.created_at or BASE_TS, row.email)
    )
    for idx, user in enumerate(sorted_users):
        language_code = LOCALIZATION_LANG_CODES[idx % len(LOCALIZATION_LANG_CODES)]
        use_org_default = idx % 4 == 0
        if user.id == admin_user_id:
            # Keep seeded admin in a non-default locale so translation overlays are
            # immediately visible after `make seed-db`.
            language_code = "tr"
            use_org_default = False
        upsert_row(
            db,
            UserLocalizationPreference,
            pk_field="user_id",
            pk_value=user.id,
            language_code=None if use_org_default else language_code,
            use_org_default=use_org_default,
        )

    for doc in (
        db.execute(select(Doc).order_by(Doc.created_at.asc(), Doc.id.asc()))
        .scalars()
        .all()
    ):
        upsert_translation_variants_for_fields(
            db,
            content_kind="doc",
            content_id=doc.id,
            fields={
                "title": doc.title,
                "content": doc.content_md,
            },
            actor_user_id=admin_user_id,
        )

    for comment in (
        db.execute(
            select(DocComment).order_by(
                DocComment.created_at.asc(), DocComment.id.asc()
            )
        )
        .scalars()
        .all()
    ):
        upsert_translation_variants_for_fields(
            db,
            content_kind="doc_comment",
            content_id=comment.id,
            fields={"body": comment.body_md},
            actor_user_id=admin_user_id,
        )

    for sop in (
        db.execute(select(Sop).order_by(Sop.created_at.asc(), Sop.id.asc()))
        .scalars()
        .all()
    ):
        upsert_translation_variants_for_fields(
            db,
            content_kind="sop",
            content_id=sop.id,
            fields={
                "title": sop.title,
                "overview": sop.overview_md,
            },
            actor_user_id=admin_user_id,
        )

    for step in (
        db.execute(
            select(SopStep).order_by(
                SopStep.sop_id.asc(), SopStep.step_order.asc(), SopStep.id.asc()
            )
        )
        .scalars()
        .all()
    ):
        upsert_translation_variants_for_fields(
            db,
            content_kind="sop_step",
            content_id=step.id,
            fields={
                "title": step.title,
                "body": step.body_md,
            },
            actor_user_id=admin_user_id,
        )

    for incident in (
        db.execute(
            select(Incident).order_by(Incident.created_at.asc(), Incident.id.asc())
        )
        .scalars()
        .all()
    ):
        upsert_translation_variants_for_fields(
            db,
            content_kind="incident",
            content_id=incident.id,
            fields={
                "title": incident.title,
                "summary": incident.summary_md,
            },
            actor_user_id=admin_user_id,
        )

    for meta in (
        db.execute(select(IncidentMeta).order_by(IncidentMeta.incident_id.asc()))
        .scalars()
        .all()
    ):
        upsert_translation_variants_for_fields(
            db,
            content_kind="incident",
            content_id=meta.incident_id,
            fields={"postmortem": meta.postmortem_md},
            actor_user_id=admin_user_id,
        )

    for timeline in (
        db.execute(
            select(IncidentTimeline).order_by(
                IncidentTimeline.ts.asc(), IncidentTimeline.id.asc()
            )
        )
        .scalars()
        .all()
    ):
        upsert_translation_variants_for_fields(
            db,
            content_kind="incident_timeline",
            content_id=timeline.id,
            fields={"entry": timeline.entry_md},
            actor_user_id=admin_user_id,
        )

    for item in (
        db.execute(
            select(IncidentActionItem).order_by(
                IncidentActionItem.created_at.asc(), IncidentActionItem.id.asc()
            )
        )
        .scalars()
        .all()
    ):
        upsert_translation_variants_for_fields(
            db,
            content_kind="incident_action_item",
            content_id=item.id,
            fields={
                "title": item.title,
                "notes": item.notes_md,
            },
            actor_user_id=admin_user_id,
        )

    for task in (
        db.execute(select(Task).order_by(Task.created_at.asc(), Task.id.asc()))
        .scalars()
        .all()
    ):
        upsert_translation_variants_for_fields(
            db,
            content_kind="task",
            content_id=task.id,
            fields={
                "title": task.title,
                "description": task.description,
            },
            actor_user_id=admin_user_id,
        )

    for comment in (
        db.execute(
            select(TaskComment).order_by(
                TaskComment.created_at.asc(), TaskComment.id.asc()
            )
        )
        .scalars()
        .all()
    ):
        upsert_translation_variants_for_fields(
            db,
            content_kind="task_comment",
            content_id=comment.id,
            fields={"body": comment.body},
            actor_user_id=admin_user_id,
        )

    for org_item in (
        db.execute(
            select(OrganizationItem).order_by(
                OrganizationItem.kind.asc(),
                OrganizationItem.name.asc(),
                OrganizationItem.id.asc(),
            )
        )
        .scalars()
        .all()
    ):
        meta_fields = _translation_meta_fields(_decode_json_map(org_item.meta_json))
        fields: dict[str, str | None] = {"name": org_item.name}
        for key, value in meta_fields.items():
            fields[key] = value
        upsert_translation_variants_for_fields(
            db,
            content_kind=f"org_{org_item.kind.strip().lower()}",
            content_id=org_item.id,
            fields=fields,
            actor_user_id=admin_user_id,
        )

    db.commit()


def seed_localization_queue_demo(
    db: Session,
    users: dict[str, User],
    refs: dict[str, dict[str, Any]],
) -> None:
    refs["translation_jobs"] = {}
    queue_specs = [
        (
            refs["docs"]["platform-ops:api-release-checklist"].id,
            "doc",
            "title",
            "tr",
            "done",
            1,
            None,
            None,
            "seed_history",
            "admin",
            ts(days_ago=3),
            ts(days_ago=3),
            ts(days_ago=3),
        ),
        (
            refs["docs"]["customer-support:refund-eligibility-matrix"].id,
            "doc",
            "content",
            "de",
            "retry",
            2,
            "Provider rate limit; retry queued after glossary refresh.",
            BASE_TS + timedelta(minutes=30),
            "bulk_queue",
            "support_qa",
            ts(days_ago=0, hours=2),
            ts(days_ago=0, hours=1),
            None,
        ),
        (
            refs["incidents"]["store-ops:lane-4-printer-failure"].id,
            "incident",
            "summary",
            "tr",
            "queued",
            0,
            None,
            BASE_TS + timedelta(minutes=10),
            "auto_write",
            "member",
            ts(days_ago=0, hours=1),
            ts(days_ago=0, hours=1),
            None,
        ),
    ]
    for (
        content_id,
        content_kind,
        field_key,
        language_code,
        status,
        attempt_count,
        last_error,
        next_attempt_at,
        triggered_by,
        actor_key,
        created_at,
        updated_at,
        completed_at,
    ) in queue_specs:
        source = db.scalar(
            select(LocalizationTranslationSource).where(
                LocalizationTranslationSource.content_kind == content_kind,
                LocalizationTranslationSource.content_id == content_id,
                LocalizationTranslationSource.field_key == field_key,
            )
        )
        if source is None:
            continue
        job_key = f"{content_kind}:{content_id}:{field_key}:{language_code}"
        job = upsert_row(
            db,
            LocalizationTranslationJob,
            pk_field="id",
            pk_value=seed_uuid("localization-job", job_key),
            source_id=source.id,
            content_kind=content_kind,
            content_id=content_id,
            field_key=field_key,
            language_code=language_code,
            source_language_code=source.source_language_code,
            source_text=source.source_text,
            source_hash=source.source_hash,
            source_version=source.source_version,
            provider="openai",
            model="gpt-5-mini",
            status=status,
            idempotency_key=f"seed-job:{job_key}:{source.source_version}",
            attempt_count=attempt_count,
            max_attempts=4,
            backoff_seconds=30,
            next_attempt_at=next_attempt_at,
            last_error=last_error,
            triggered_by=triggered_by,
            actor_user_id=users[actor_key].id,
            created_at=created_at,
            updated_at=updated_at,
            completed_at=completed_at,
        )
        refs["translation_jobs"][job_key] = job


def count_rows(db: Session) -> dict[str, int]:
    models = [
        ("users", User),
        ("notification_prefs", UserNotificationPreference),
        ("notification_pref_audit", UserNotificationPreferenceAudit),
        ("dashboard_prefs", UserDashboardPreference),
        ("user_sessions", UserSession),
        ("auth_session_policy", AuthSessionPolicy),
        ("user_security_state", UserSecurityState),
        ("spaces", Space),
        ("custom_roles", CustomRole),
        ("org_units", OrganizationUnit),
        ("organization_items", OrganizationItem),
        ("organization_item_links", OrganizationItemLink),
        ("organization_audit_events", OrganizationAuditEvent),
        ("branding_drafts", BrandingDraft),
        ("branding_revisions", BrandingRevision),
        ("folders", Folder),
        ("docs", Doc),
        ("doc_versions", DocVersion),
        ("doc_meta", DocMeta),
        ("doc_review_assignments", DocReviewAssignment),
        ("doc_comments", DocComment),
        ("doc_mentions", DocMentionNotification),
        ("kb_policies", KbSpacePolicy),
        ("sops", Sop),
        ("sop_steps", SopStep),
        ("sop_meta", SopMeta),
        ("sop_step_meta", SopStepMeta),
        ("sop_step_rules", SopStepEvidenceRule),
        ("sop_approval_stages", SopApprovalStage),
        ("sop_approval_decisions", SopApprovalDecision),
        ("sop_runs", SopRun),
        ("sop_run_steps", SopRunStep),
        ("sop_run_schedules", SopRunSchedule),
        ("sop_reminder_dispatches", SopReminderDispatch),
        ("sop_follow_ups", SopRunFollowUp),
        ("incidents", Incident),
        ("incident_timeline", IncidentTimeline),
        ("incident_meta", IncidentMeta),
        ("incident_timeline_meta", IncidentTimelineMeta),
        ("incident_profiles", IncidentProfile),
        ("incident_templates", IncidentTemplate),
        ("incident_impacts", IncidentImpactService),
        ("incident_status_updates", IncidentStatusUpdate),
        ("incident_action_items", IncidentActionItem),
        ("incident_action_reminders", IncidentActionReminder),
        ("incident_links", IncidentLink),
        ("incident_status_transitions", IncidentStatusTransition),
        ("tasks", Task),
        ("task_comments", TaskComment),
        ("task_execution_profiles", TaskExecutionProfile),
        ("task_reminder_dispatches", TaskReminderDispatch),
        ("media_assets", MediaAsset),
        ("media_meta", MediaAssetMeta),
        ("media_attachments", MediaAttachment),
        ("media_usage", MediaUsage),
        ("localization_settings", OrganizationLocalizationSetting),
        ("localization_languages", LocalizationLanguage),
        ("localization_bundles", LocalizationBundle),
        ("localization_user_preferences", UserLocalizationPreference),
        ("localization_translation_settings", LocalizationTranslationSetting),
        ("localization_translation_sources", LocalizationTranslationSource),
        ("localization_translation_variants", LocalizationTranslationVariant),
        ("localization_translation_jobs", LocalizationTranslationJob),
        ("events", Event),
    ]
    return {
        name: int(db.scalar(select(func.count()).select_from(model)) or 0)
        for name, model in models
    }


def reset_database(db: Session) -> None:
    table_names = [
        table.name
        for table in Base.metadata.sorted_tables
        if table.name != "alembic_version"
    ]
    if not table_names:
        return

    dialect = db.bind.dialect.name if db.bind is not None else ""
    if dialect == "postgresql":
        quoted = ", ".join(f'"{name}"' for name in table_names)
        db.execute(text(f"TRUNCATE TABLE {quoted} RESTART IDENTITY CASCADE"))
        db.commit()
        return

    if dialect == "sqlite":
        db.execute(text("PRAGMA foreign_keys = OFF"))
        for table_name in reversed(table_names):
            db.execute(text(f'DELETE FROM "{table_name}"'))
        db.execute(text("DELETE FROM sqlite_sequence"))
        db.execute(text("PRAGMA foreign_keys = ON"))
        db.commit()
        return

    for table in reversed(Base.metadata.sorted_tables):
        if table.name == "alembic_version":
            continue
        db.execute(table.delete())
    db.commit()


def seed_dataset_present(db: Session) -> bool:
    """Return whether the durable demo dataset already exists in this database."""
    admin_exists = bool(
        db.scalar(
            select(func.count())
            .select_from(User)
            .where(User.email == "admin@admin.com")
        )
    )
    space_exists = bool(db.scalar(select(func.count()).select_from(Space)))
    return admin_exists and space_exists


def seed_all(db: Session) -> None:
    refs: dict[str, dict[str, Any]] = {
        "spaces": {},
        "folders": {},
        "docs": {},
        "sops": {},
        "incidents": {},
        "tasks": {},
        "task_comments": {},
        "doc_comments": {},
        "sop_runs": {},
        "sop_run_steps": {},
        "sop_run_schedules": {},
        "media": {},
        "incident_templates": {},
        "translation_jobs": {},
    }

    users = seed_users(db)
    refs["users"] = users  # convenience for debugging

    seed_platform_ops(db, users, refs)
    seed_store_ops(db, users, refs)
    seed_support_ops(db, users, refs)
    seed_regional_spaces(db, users, refs)
    seed_extended_records(db, users, refs)

    db.flush()
    db.commit()

    admin_service.sync_organization_items(db)
    seed_localization_data(db, users)
    seed_localization_queue_demo(db, users, refs)
    db.commit()

    # Persist referenced rows (users/spaces/etc.) before analytics events.
    # SQLAlchemy may autoflush `Event` inserts before unrelated pending rows
    # because we don't define ORM relationships between these models.
    db.flush()
    seed_analytics(db, users, refs)
    db.commit()

    counts = count_rows(db)
    print("Seed completed.")
    print("Users (all seeded accounts use password: password):")
    for user_key in sorted(users.keys()):
        user = users[user_key]
        print(f"  {user.name:22} {user.email} / password")
    print("Row counts:")
    for key in [
        "users",
        "notification_prefs",
        "notification_pref_audit",
        "dashboard_prefs",
        "user_sessions",
        "auth_session_policy",
        "user_security_state",
        "spaces",
        "custom_roles",
        "org_units",
        "organization_items",
        "organization_item_links",
        "branding_drafts",
        "branding_revisions",
        "folders",
        "docs",
        "doc_meta",
        "doc_comments",
        "doc_versions",
        "sops",
        "sop_steps",
        "sop_runs",
        "incidents",
        "incident_profiles",
        "incident_templates",
        "incident_impacts",
        "incident_status_updates",
        "incident_action_items",
        "incident_action_reminders",
        "tasks",
        "task_comments",
        "task_execution_profiles",
        "task_reminder_dispatches",
        "media_assets",
        "incident_timeline",
        "localization_languages",
        "localization_bundles",
        "localization_translation_sources",
        "localization_translation_variants",
        "localization_translation_jobs",
        "events",
    ]:
        print(f"  {key}: {counts[key]}")


def main() -> None:
    reset_requested = any(arg in {"--reset", "--erase"} for arg in sys.argv[1:])

    if reset_requested:
        inspector = inspect(engine)
        existing_tables = inspector.get_table_names()
        if existing_tables:
            dialect = engine.dialect.name
            with engine.begin() as conn:
                if dialect == "postgresql":
                    for table_name in existing_tables:
                        conn.exec_driver_sql(
                            f'DROP TABLE IF EXISTS "{table_name}" CASCADE'
                        )
                elif dialect == "sqlite":
                    conn.exec_driver_sql("PRAGMA foreign_keys = OFF")
                    for table_name in existing_tables:
                        conn.exec_driver_sql(f'DROP TABLE IF EXISTS "{table_name}"')
                    conn.exec_driver_sql("PRAGMA foreign_keys = ON")
                else:
                    for table_name in existing_tables:
                        conn.exec_driver_sql(f'DROP TABLE IF EXISTS "{table_name}"')

    init_db()
    with SessionLocal() as db:
        if not reset_requested and seed_dataset_present(db):
            print("Seed data already present; skipping demo seed.")
            return
        seed_all(db)


if __name__ == "__main__":
    main()
