# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Pydantic payloads for administration and organization management APIs."""

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class UserOut(BaseModel):
    id: str
    email: str
    name: str
    global_role: str
    is_active: bool = True
    must_change_password: bool = False
    invited_at: datetime | None = None
    invite_expires_at: datetime | None = None
    meta: dict[str, object] | None = None
    notification_prefs_synced: bool = False
    notification_prefs_updated_at: datetime | None = None
    notification_prefs_change_count: int = 0
    notification_prefs_last_change_at: datetime | None = None


class UserCreateIn(BaseModel):
    email: str = Field(min_length=3, max_length=320)
    name: str = Field(min_length=1, max_length=200)
    password: str = Field(min_length=6, max_length=200)
    global_role: str = Field(default="member", min_length=1, max_length=50)
    meta: dict[str, object] | None = None


class UserUpdateIn(BaseModel):
    email: str | None = Field(default=None, min_length=3, max_length=320)
    name: str | None = Field(default=None, min_length=1, max_length=200)
    password: str | None = Field(default=None, min_length=6, max_length=200)
    global_role: str | None = Field(default=None, min_length=1, max_length=50)
    meta: dict[str, object] | None = None


class UserOnboardingTokenOut(BaseModel):
    user_id: str
    email: str
    onboarding_token: str
    onboarding_url: str | None = None
    expires_at: datetime | None = None


class AdminSpaceOut(BaseModel):
    id: str
    name: str
    slug: str
    owner_user_id: str | None = None
    owner_name: str | None = None
    region_code: str | None = None
    meta: dict[str, object] | None = None
    member_count: int
    created_at: datetime | None = None


class AdminSpaceCreateIn(BaseModel):
    name: str
    slug: str
    region_code: str | None = Field(default=None, max_length=120)
    meta: dict[str, object] | None = None
    owner_user_id: str | None = None


class AdminSpaceUpdateIn(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    slug: str | None = Field(default=None, min_length=1, max_length=200)
    owner_user_id: str | None = None
    region_code: str | None = Field(default=None, max_length=120)
    meta: dict[str, object] | None = None


class AdminSpaceDeleteOut(BaseModel):
    ok: bool = True
    deleted_space_id: str


class CustomRoleOut(BaseModel):
    id: str
    role_key: str
    name: str
    description: str | None = None
    effective_level: str
    active: bool
    meta: dict[str, object] | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None


class CustomRoleCreateIn(BaseModel):
    role_key: str = Field(min_length=2, max_length=100)
    name: str = Field(min_length=1, max_length=200)
    description: str | None = Field(default=None, max_length=600)
    effective_level: str = Field(min_length=1, max_length=50)
    active: bool = True
    meta: dict[str, object] | None = None


class CustomRoleUpdateIn(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    description: str | None = Field(default=None, max_length=600)
    effective_level: str | None = Field(default=None, min_length=1, max_length=50)
    active: bool | None = None
    meta: dict[str, object] | None = None


class BrandingOut(BaseModel):
    company_name: str | None = None
    application_title: str | None = None
    application_short_name: str | None = None
    web_description: str | None = None
    apple_web_app_title: str | None = None
    logo_url: str | None = None
    light_logo_url: str | None = None
    dark_logo_url: str | None = None
    favicon_url: str | None = None
    login_background_url: str | None = None
    light_seed_hex: str | None = None
    dark_accent_hex: str | None = None
    dark_bg_hex: str | None = None
    browser_theme_hex: str | None = None
    install_background_hex: str | None = None
    resolved_app_title: str = "OpsAtlas"
    resolved_application_short_name: str = "OpsAtlas"
    resolved_web_description: str = "OpsAtlas is a self-hosted operations workspace for procedures, incidents, knowledge, and follow-up work."
    resolved_apple_web_app_title: str = "OpsAtlas"
    resolved_theme_color_hex: str = "#0F67E8"
    resolved_install_background_hex: str = "#0A0D12"
    updated_at: datetime | None = None


class BrandingUpdateIn(BaseModel):
    company_name: str | None = Field(default=None, max_length=200)
    application_title: str | None = Field(default=None, max_length=200)
    application_short_name: str | None = Field(default=None, max_length=80)
    web_description: str | None = Field(default=None, max_length=600)
    apple_web_app_title: str | None = Field(default=None, max_length=80)
    logo_url: str | None = Field(default=None, max_length=1000)
    light_logo_url: str | None = Field(default=None, max_length=1000)
    dark_logo_url: str | None = Field(default=None, max_length=1000)
    favicon_url: str | None = Field(default=None, max_length=1000)
    login_background_url: str | None = Field(default=None, max_length=1000)
    light_seed_hex: str | None = Field(default=None, max_length=9)
    dark_accent_hex: str | None = Field(default=None, max_length=9)
    dark_bg_hex: str | None = Field(default=None, max_length=9)
    browser_theme_hex: str | None = Field(default=None, max_length=9)
    install_background_hex: str | None = Field(default=None, max_length=9)


class BrandingHistoryEntryOut(BaseModel):
    id: str
    revision_number: int
    source_kind: str
    source_revision_id: str | None = None
    summary: str | None = None
    published_by_user_id: str | None = None
    published_by_name: str | None = None
    published_at: datetime | None = None
    snapshot: BrandingOut


class BrandingAdminStateOut(BaseModel):
    published: BrandingOut
    draft: BrandingOut
    history: list[BrandingHistoryEntryOut] = Field(default_factory=list)
    has_unpublished_changes: bool = False


class BrandingManifestIconOut(BaseModel):
    src: str
    sizes: str
    type: str
    purpose: str | None = None


class BrandingManifestOut(BaseModel):
    name: str
    short_name: str
    start_url: str = "."
    display: str = "standalone"
    background_color: str
    theme_color: str
    description: str
    orientation: str = "portrait-primary"
    prefer_related_applications: bool = False
    icons: list[BrandingManifestIconOut] = Field(default_factory=list)


class OrganizationUnitOut(BaseModel):
    id: str
    name: str
    slug: str
    unit_type: str
    parent_id: str | None = None
    active: bool
    meta: dict[str, object] | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None


class OrganizationUnitCreateIn(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    slug: str = Field(min_length=1, max_length=200)
    unit_type: str = Field(min_length=1, max_length=50)
    parent_id: str | None = None
    active: bool = True
    meta: dict[str, object] | None = None


class OrganizationUnitUpdateIn(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    slug: str | None = Field(default=None, min_length=1, max_length=200)
    unit_type: str | None = Field(default=None, min_length=1, max_length=50)
    parent_id: str | None = None
    active: bool | None = None
    meta: dict[str, object] | None = None


class OrganizationItemOut(BaseModel):
    id: str
    kind: str
    entity_id: str | None = None
    slug: str | None = None
    name: str
    active: bool
    meta: dict[str, object] | None = None
    details: dict[str, object] | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None


class OrganizationItemLinkOut(BaseModel):
    id: str
    parent_kind: str
    parent_id: str
    parent_name: str | None = None
    child_kind: str
    child_id: str
    child_name: str | None = None
    grant_role: str
    inherit_to_descendants: bool
    active: bool
    created_at: datetime | None = None
    updated_at: datetime | None = None


class OrganizationItemLinkCreateIn(BaseModel):
    parent_kind: str = Field(min_length=1, max_length=50)
    parent_id: str = Field(min_length=1, max_length=120)
    child_kind: str = Field(min_length=1, max_length=50)
    child_id: str = Field(min_length=1, max_length=120)
    grant_role: str = Field(default="member", min_length=1, max_length=50)
    inherit_to_descendants: bool = True
    active: bool = True


class OrganizationItemLinkPairIn(BaseModel):
    parent_kind: str = Field(min_length=1, max_length=50)
    parent_id: str = Field(min_length=1, max_length=120)
    child_kind: str = Field(min_length=1, max_length=50)
    child_id: str = Field(min_length=1, max_length=120)


class OrganizationRoleRebindIn(BaseModel):
    role_key: str = Field(min_length=1, max_length=120)
    user_ids: list[str] = Field(default_factory=list, min_length=1)


class OrganizationItemLinkMutationPlanIn(BaseModel):
    link: list[OrganizationItemLinkCreateIn] = Field(default_factory=list)
    unlink: list[OrganizationItemLinkPairIn] = Field(default_factory=list)
    rebind_roles: list[OrganizationRoleRebindIn] = Field(default_factory=list)
    dry_run: bool = False


class OrganizationWhyAccessGrantOut(BaseModel):
    link_id: str | None = None
    department_id: str
    department_name: str | None = None
    grant_role: str
    effective_role: str | None = None
    inherit_to_descendants: bool
    source: Literal["direct_department", "ancestor_department"]


class OrganizationWhyAccessOut(BaseModel):
    user_id: str
    user_name: str | None = None
    space_id: str
    space_name: str | None = None
    system_role: str | None = None
    system_role_effective: str | None = None
    direct_department_ids: list[str] = Field(default_factory=list)
    ancestor_department_ids: list[str] = Field(default_factory=list)
    matching_grants: list[OrganizationWhyAccessGrantOut] = Field(default_factory=list)
    selected_grant_role: str | None = None
    selected_effective_role: str | None = None
    final_role: str | None = None
    final_effective_role: str | None = None
    access_granted: bool = False


class OrganizationRoleImpactGlobalRoleChangeIn(BaseModel):
    user_id: str = Field(min_length=1, max_length=120)
    role_key: str = Field(min_length=1, max_length=120)


class OrganizationRoleImpactSpaceGrantChangeIn(BaseModel):
    department_id: str = Field(min_length=1, max_length=120)
    space_id: str = Field(min_length=1, max_length=120)
    grant_role: str = Field(default="member", min_length=1, max_length=120)
    inherit_to_descendants: bool = True
    active: bool = True


class OrganizationRoleImpactSpaceGrantRemovalIn(BaseModel):
    department_id: str = Field(min_length=1, max_length=120)
    space_id: str = Field(min_length=1, max_length=120)


class OrganizationRoleImpactSimulationIn(BaseModel):
    global_role_changes: list[OrganizationRoleImpactGlobalRoleChangeIn] = Field(default_factory=list)
    space_grant_changes: list[OrganizationRoleImpactSpaceGrantChangeIn] = Field(default_factory=list)
    space_grant_removals: list[OrganizationRoleImpactSpaceGrantRemovalIn] = Field(default_factory=list)


class OrganizationRoleImpactSimulationOut(BaseModel):
    ok: bool = True
    simulated_global_role_changes: int = 0
    simulated_space_grant_changes: int = 0
    simulated_space_grant_removals: int = 0
    access_impact: "OrganizationAccessImpactOut"


class OrganizationAccessImpactChangeOut(BaseModel):
    user_id: str
    user_name: str | None = None
    space_id: str
    space_name: str | None = None
    before_role: str | None = None
    after_role: str | None = None


class OrganizationAccessImpactOut(BaseModel):
    affected_user_count: int = 0
    affected_space_count: int = 0
    changed_membership_count: int = 0
    truncated: bool = False
    changes: list[OrganizationAccessImpactChangeOut] = Field(default_factory=list)


class OrganizationItemLinkBulkResultOut(BaseModel):
    ok: bool = True
    dry_run: bool = False
    link_created: int = 0
    link_updated: int = 0
    link_deleted: int = 0
    role_rebound: int = 0
    access_impact: OrganizationAccessImpactOut | None = None


class OrganizationGraphIntegrityIssueOut(BaseModel):
    code: str
    severity: Literal["error", "warning"]
    message: str
    item_id: str | None = None
    link_id: str | None = None
    parent_id: str | None = None
    child_id: str | None = None


class OrganizationGraphIntegrityOut(BaseModel):
    ok: bool
    checked_at: datetime
    item_count: int
    link_count: int
    issue_count: int
    issues: list[OrganizationGraphIntegrityIssueOut] = Field(default_factory=list)


class OrganizationRoleBindingOut(BaseModel):
    user_id: str
    role_key: str
    source: str = "item_link"


class OrganizationGraphPackageOut(BaseModel):
    version: str
    exported_at: datetime
    metadata: dict[str, object] | None = None
    items: list[OrganizationItemOut] = Field(default_factory=list)
    links: list[OrganizationItemLinkOut] = Field(default_factory=list)
    role_bindings: list[OrganizationRoleBindingOut] = Field(default_factory=list)


class OrganizationGraphImportIn(BaseModel):
    package: dict[str, object]
    dry_run: bool = True


class OrganizationGraphImportOut(BaseModel):
    ok: bool = True
    dry_run: bool = True
    validated: bool = False
    applied: bool = False
    created_items: int = 0
    updated_items: int = 0
    upserted_links: int = 0
    role_rebound: int = 0
    errors: list[str] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)


class OrganizationAuditEventOut(BaseModel):
    id: str
    scope_kind: str
    action: str
    item_kind: str | None = None
    item_id: str | None = None
    link_parent_kind: str | None = None
    link_parent_id: str | None = None
    link_child_kind: str | None = None
    link_child_id: str | None = None
    actor_user_id: str | None = None
    actor_name: str | None = None
    summary: str | None = None
    before: dict[str, object] | None = None
    after: dict[str, object] | None = None
    created_at: datetime | None = None
