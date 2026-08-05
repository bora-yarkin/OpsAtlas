# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone

import pytest
from sqlalchemy.orm import Session

from app.core.db import Base, SessionLocal, engine, init_db
from app.modules.analytics.models import Event
from app.modules.auth.models import User
from app.modules.kb import repo as kb_repo
from app.modules.kb import service as kb_service
from app.modules.kb.models import Doc, Folder
from app.modules.localization.models import (
    LocalizationTranslationSource,
    LocalizationTranslationVariant,
    UserLocalizationPreference,
)
from app.modules.spaces.models import Space


@pytest.fixture(autouse=True)
def reset_db() -> None:
    init_db()
    Base.metadata.drop_all(bind=engine)
    init_db()


def _seed_user_and_space() -> tuple[str, str]:
    with SessionLocal() as db:
        user = User(
            id=str(uuid.uuid4()),
            email="kb-admin@example.com",
            name="KB Admin",
            password_hash="test-hash",
            global_role="admin",
            is_active=True,
            must_change_password=False,
        )
        space = Space(
            id=str(uuid.uuid4()),
            name="Knowledge Base",
            slug=f"knowledge-base-{uuid.uuid4().hex[:8]}",
            owner_user_id=user.id,
            region_code="eu-central",
            meta_json=None,
        )
        db.add(user)
        db.add(space)
        db.commit()
        return user.id, space.id


def _seed_published_doc(
    db: Session,
    *,
    user_id: str,
    space_id: str,
    title: str,
    slug: str,
    content_md: str,
) -> Doc:
    doc = Doc(
        id=str(uuid.uuid4()),
        space_id=space_id,
        folder_id=None,
        title=title,
        slug=slug,
        status="published",
        content_md=content_md,
        created_by=user_id,
        updated_by=user_id,
        published_at=datetime.now(timezone.utc),
    )
    db.add(doc)
    db.flush()
    return doc


def _seed_doc_translation(
    db: Session,
    *,
    user_id: str,
    doc_id: str,
    field_key: str,
    source_text: str,
    translated_text: str,
    language_code: str,
) -> None:
    source_id = f"doc:{doc_id}:{field_key}"
    source = LocalizationTranslationSource(
        id=source_id,
        content_kind="doc",
        content_id=doc_id,
        field_key=field_key,
        source_language_code="en",
        source_text=source_text,
        source_hash=f"hash-{uuid.uuid4().hex[:8]}",
        source_version=1,
        active=True,
        updated_by_user_id=user_id,
    )
    variant = LocalizationTranslationVariant(
        id=str(uuid.uuid4()),
        source_id=source_id,
        content_kind="doc",
        content_id=doc_id,
        field_key=field_key,
        language_code=language_code,
        translated_text=translated_text,
        status="approved",
        source_language_code="en",
        source_version=1,
        locked=True,
    )
    db.add(source)
    db.add(variant)


def _set_user_language(db: Session, *, user_id: str, language_code: str) -> None:
    db.merge(
        UserLocalizationPreference(
            user_id=user_id,
            language_code=language_code,
            use_org_default=False,
        )
    )


def test_list_docs_filtered_accepts_blank_root_folder_id_on_sqlite() -> None:
    user_id, space_id = _seed_user_and_space()

    with SessionLocal() as db:
        doc = Doc(
            id=str(uuid.uuid4()),
            space_id=space_id,
            folder_id=None,
            title="Root Runbook",
            slug=f"root-runbook-{uuid.uuid4().hex[:8]}",
            status="draft",
            content_md="<p>Root doc</p>",
            created_by=user_id,
            updated_by=user_id,
        )
        db.add(doc)
        db.commit()

        docs = kb_service.list_docs_filtered(
            db,
            space_id=space_id,
            folder_id="",
            published_only=False,
        )

        assert [row.id for row in docs] == [doc.id]


def test_list_folders_treats_blank_parent_id_as_root() -> None:
    _, space_id = _seed_user_and_space()

    with SessionLocal() as db:
        folder = Folder(
            id=str(uuid.uuid4()),
            space_id=space_id,
            parent_id=None,
            name="Runbooks",
            path="/Runbooks",
        )
        db.add(folder)
        db.commit()

        folders = kb_repo.list_folders(db, space_id, "")

        assert [row.id for row in folders] == [folder.id]


def test_search_docs_matches_localized_translation_variants_with_transliteration() -> None:
    user_id, space_id = _seed_user_and_space()

    with SessionLocal() as db:
        doc = _seed_published_doc(
            db,
            user_id=user_id,
            space_id=space_id,
            title="Refund Policy",
            slug="refund-policy",
            content_md="Steps for approving customer refunds.",
        )
        _seed_doc_translation(
            db,
            user_id=user_id,
            doc_id=doc.id,
            field_key="title",
            source_text=doc.title,
            translated_text="Rückerstattung",
            language_code="de",
        )
        _seed_doc_translation(
            db,
            user_id=user_id,
            doc_id=doc.id,
            field_key="content",
            source_text=doc.content_md,
            translated_text="Ablauf für Rückerstattungen an Kundinnen und Kunden.",
            language_code="de",
        )
        _set_user_language(db, user_id=user_id, language_code="de")
        db.commit()

        docs = kb_service.search_docs(
            db,
            user_id=user_id,
            space_id=space_id,
            query="rueckerstattung",
            limit=5,
        )

        assert [row.id for row in docs][:1] == [doc.id]


def test_search_suggestions_include_localized_terms_and_popular_queries() -> None:
    user_id, space_id = _seed_user_and_space()

    with SessionLocal() as db:
        _set_user_language(db, user_id=user_id, language_code="de")
        db.add(
            Event(
                id=str(uuid.uuid4()),
                user_id=user_id,
                session_id="kb-search",
                event_type="search_query_issued",
                space_id=space_id,
                entity_type="doc",
                path=f"/spaces/{space_id}",
                meta_json=json.dumps({"surface": "kb", "query": "refund workflow"}),
            )
        )
        db.add(
            Event(
                id=str(uuid.uuid4()),
                user_id=user_id,
                session_id="kb-search",
                event_type="open",
                space_id=space_id,
                entity_type="doc",
                path=f"/spaces/{space_id}",
                meta_json=json.dumps(
                    {
                        "search_query": "refund workflow",
                        "positive_search_outcome": True,
                    }
                ),
            )
        )
        db.commit()

        kb_service.update_space_policy(
            db,
            space_id=space_id,
            trash_retention_days=30,
            localized_synonyms={
                "de": {"rückerstattung": ["rueckerstattung", "erstattung"]}
            },
            localized_lexicon={"de": ["rückerstattung leitfaden"]},
        )

        localized_suggestions = kb_service.search_suggestions(
            db,
            user_id=user_id,
            space_id=space_id,
            query="rue",
            limit=10,
        )
        popular_suggestions = kb_service.search_suggestions(
            db,
            user_id=user_id,
            space_id=space_id,
            query="refund",
            limit=10,
        )

        assert any(item.query == "rückerstattung" for item in localized_suggestions)
        assert any(item.query == "refund workflow" for item in popular_suggestions)


def test_update_space_policy_runs_localized_relevance_benchmarks() -> None:
    user_id, space_id = _seed_user_and_space()

    with SessionLocal() as db:
        doc = _seed_published_doc(
            db,
            user_id=user_id,
            space_id=space_id,
            title="Refund Policy",
            slug="refund-policy",
            content_md="Steps for approving customer refunds.",
        )
        _seed_doc_translation(
            db,
            user_id=user_id,
            doc_id=doc.id,
            field_key="title",
            source_text=doc.title,
            translated_text="Rückerstattung",
            language_code="de",
        )
        db.commit()

        policy = kb_service.update_space_policy(
            db,
            space_id=space_id,
            trash_retention_days=30,
            relevance_benchmarks=[
                {
                    "language_code": "de",
                    "query": "rueckerstattung",
                    "expected_slug": doc.slug,
                }
            ],
        )

        assert policy.relevance_benchmark_summary.total_cases == 1
        assert policy.relevance_benchmark_summary.passed_cases == 1
        assert policy.relevance_benchmark_summary.score >= 1.0
        assert policy.relevance_benchmark_summary.results[0].matched_slug == doc.slug
