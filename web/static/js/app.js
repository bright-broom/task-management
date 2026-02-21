/**
 * M2X Task Management System - Frontend Application
 *
 * @description Factory task management system with multi-tenant support
 * @version 1.0.0
 */

(function () {
    "use strict";

    // ==========================================================================
    // Configuration
    // ==========================================================================

    const CONFIG = {
        api: {
            tenants: "/api/tenants",
            equipments: (tenantId) => `/api/tenants/${tenantId}/equipments`,
            parts: (tenantId) => `/api/tenants/${tenantId}/parts`,
            tasks: (tenantId) => `/api/tenants/${tenantId}/tasks`,
            taskDetails: (taskId) => `/api/tasks/${taskId}/details`,
            customFields: (tenantId) => `/api/tenants/${tenantId}/custom_fields`,
            stats: (tenantId) => `/api/tenants/${tenantId}/stats`,
        },
        labels: {
            status: {
                open: "未着手",
                todo: "未着手",
                in_progress: "進行中",
                done: "完了",
                completed: "完了",
            },
            priority: {
                low: "低",
                medium: "中",
                high: "高",
                urgent: "緊急",
            },
            category: {
                maintenance: "メンテナンス",
                repair: "修理",
                inspection: "点検",
                cleaning: "清掃",
                other: "その他",
            },
            fieldType: {
                text: "テキスト",
                number: "数値",
                date: "日付",
                boolean: "真偽値",
                select: "選択",
            },
        },
        styles: {
            status: {
                open: "bg-amber-100 text-amber-800 border-amber-200",
                todo: "bg-amber-100 text-amber-800 border-amber-200",
                in_progress: "bg-blue-100 text-blue-800 border-blue-200",
                done: "bg-emerald-100 text-emerald-800 border-emerald-200",
                completed: "bg-emerald-100 text-emerald-800 border-emerald-200",
            },
            priority: {
                low: "bg-slate-100 text-slate-700 border-slate-200",
                medium: "bg-sky-100 text-sky-700 border-sky-200",
                high: "bg-orange-100 text-orange-700 border-orange-200",
                urgent: "bg-rose-100 text-rose-700 border-rose-200",
            },
            category: {
                maintenance: "bg-violet-100 text-violet-700",
                repair: "bg-red-100 text-red-700",
                inspection: "bg-cyan-100 text-cyan-700",
                cleaning: "bg-lime-100 text-lime-700",
                other: "bg-gray-100 text-gray-700",
            },
            fieldType: {
                text: "bg-gray-100 text-gray-700",
                number: "bg-blue-100 text-blue-700",
                date: "bg-purple-100 text-purple-700",
                boolean: "bg-green-100 text-green-700",
                select: "bg-orange-100 text-orange-700",
            },
        },
        tabs: [
            { id: "dashboard", label: "ダッシュボード", icon: "chart" },
            { id: "tasks", label: "タスク", icon: "list" },
            { id: "equipments", label: "設備", icon: "cog" },
            { id: "parts", label: "部品", icon: "cube" },
            { id: "custom-fields", label: "独自入力項目", icon: "form" },
        ],
        toast: {
            duration: 5000,
            errorClass: "bg-red-600",
            successClass: "bg-emerald-600",
        },
    };

    // ==========================================================================
    // State Management
    // ==========================================================================

    const state = {
        currentTenant: null,
        currentTab: "dashboard",
        selectedTaskId: null,
        loading: new Set(),
        cache: new Map(),
    };

    // ==========================================================================
    // Utility Functions
    // ==========================================================================

    const $ = (selector) => document.querySelector(selector);
    const $$ = (selector) => document.querySelectorAll(selector);
    const $id = (id) => document.getElementById(id);

    function escapeHtml(str) {
        if (str == null) return "";
        const div = document.createElement("div");
        div.textContent = String(str);
        return div.innerHTML;
    }

    function formatDate(dateStr) {
        if (!dateStr) return "-";
        try {
            return new Date(dateStr).toLocaleDateString("ja-JP", {
                year: "numeric",
                month: "2-digit",
                day: "2-digit",
            });
        } catch {
            return "-";
        }
    }

    function formatDateTime(dateStr) {
        if (!dateStr) return "-";
        try {
            return new Date(dateStr).toLocaleString("ja-JP", {
                year: "numeric",
                month: "2-digit",
                day: "2-digit",
                hour: "2-digit",
                minute: "2-digit",
            });
        } catch {
            return "-";
        }
    }

    function debounce(fn, delay) {
        let timeoutId;
        return function (...args) {
            clearTimeout(timeoutId);
            timeoutId = setTimeout(() => fn.apply(this, args), delay);
        };
    }

    // ==========================================================================
    // API Communication
    // ==========================================================================

    async function fetchApi(url, options = {}) {
        const { loadingKey = null, useCache = false, cacheTTL = 60000 } = options;

        if (useCache && state.cache.has(url)) {
            const cached = state.cache.get(url);
            if (Date.now() - cached.timestamp < cacheTTL) {
                return cached.data;
            }
            state.cache.delete(url);
        }

        if (loadingKey) {
            state.loading.add(loadingKey);
            updateLoadingState(loadingKey, true);
        }

        try {
            const response = await fetch(url, {
                headers: {
                    Accept: "application/json",
                    "Content-Type": "application/json",
                },
                ...options,
            });

            if (!response.ok) {
                throw new Error(`HTTP ${response.status}: ${response.statusText}`);
            }

            const data = await response.json();

            if (useCache) {
                state.cache.set(url, { data, timestamp: Date.now() });
            }

            return data;
        } catch (error) {
            console.error(`API Error (${url}):`, error);
            showToast(`データ取得エラー: ${error.message}`, "error");
            throw error;
        } finally {
            if (loadingKey) {
                state.loading.delete(loadingKey);
                updateLoadingState(loadingKey, false);
            }
        }
    }

    function updateLoadingState(key, isLoading) {
        const indicator = $(`[data-loading="${key}"]`);
        if (indicator) {
            indicator.classList.toggle("hidden", !isLoading);
        }
    }

    // ==========================================================================
    // Toast Notifications
    // ==========================================================================

    function showToast(message, type = "error") {
        const container = $id("toastContainer");
        if (!container) return;

        const toast = document.createElement("div");
        const bgClass = type === "error" ? CONFIG.toast.errorClass : CONFIG.toast.successClass;
        toast.className = `${bgClass} text-white px-4 py-3 rounded-lg shadow-lg flex items-center gap-3 transform transition-all duration-300 translate-x-full`;
        toast.setAttribute("role", "alert");
        toast.innerHTML = `
            <span class="flex-1">${escapeHtml(message)}</span>
            <button type="button" class="text-white/80 hover:text-white" aria-label="閉じる">
                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
                </svg>
            </button>
        `;

        container.appendChild(toast);

        requestAnimationFrame(() => {
            toast.classList.remove("translate-x-full");
        });

        const closeBtn = toast.querySelector("button");
        const removeToast = () => {
            toast.classList.add("translate-x-full");
            setTimeout(() => toast.remove(), 300);
        };

        closeBtn.addEventListener("click", removeToast);
        setTimeout(removeToast, CONFIG.toast.duration);
    }

    // ==========================================================================
    // UI Components
    // ==========================================================================

    const UI = {
        badge(text, colorClass, extraClass = "") {
            return `<span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium border ${colorClass} ${extraClass}">${escapeHtml(text)}</span>`;
        },

        statusBadge(status) {
            const style = CONFIG.styles.status[status] || CONFIG.styles.status.todo;
            const label = CONFIG.labels.status[status] || status;
            return UI.badge(label, style);
        },

        priorityBadge(priority) {
            if (!priority) return "";
            const style = CONFIG.styles.priority[priority] || CONFIG.styles.priority.medium;
            const label = CONFIG.labels.priority[priority] || priority;
            return UI.badge(label, style);
        },

        categoryBadge(category) {
            if (!category) return "";
            const style = CONFIG.styles.category[category] || CONFIG.styles.category.other;
            const label = CONFIG.labels.category[category] || category;
            return UI.badge(label, style);
        },

        fieldTypeBadge(type) {
            const style = CONFIG.styles.fieldType[type] || "";
            const label = CONFIG.labels.fieldType[type] || type;
            return UI.badge(label, style);
        },

        loading(lines = 3) {
            return `
                <div class="space-y-3 p-4 animate-pulse" aria-busy="true" aria-label="読み込み中">
                    ${Array(lines).fill(0).map((_, i) => `
                        <div class="h-4 bg-gray-200 rounded" style="width: ${75 - i * 15}%"></div>
                    `).join("")}
                </div>
            `;
        },

        empty(message, icon = "inbox") {
            const icons = {
                inbox: `<path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M20 13V6a2 2 0 00-2-2H6a2 2 0 00-2 2v7m16 0v5a2 2 0 01-2 2H6a2 2 0 01-2-2v-5m16 0h-2.586a1 1 0 00-.707.293l-2.414 2.414a1 1 0 01-.707.293h-3.172a1 1 0 01-.707-.293l-2.414-2.414A1 1 0 006.586 13H4"/>`,
                check: `<path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/>`,
            };
            return `
                <div class="text-center py-8">
                    <svg class="w-12 h-12 mx-auto text-gray-300 mb-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        ${icons[icon] || icons.inbox}
                    </svg>
                    <p class="text-gray-400 text-sm">${escapeHtml(message)}</p>
                </div>
            `;
        },

        card(title, subtitle, content, id = "") {
            return `
                <article class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden" ${id ? `id="${id}"` : ""}>
                    <header class="px-4 py-3 border-b border-gray-100 bg-gray-50/50">
                        <h2 class="font-semibold text-gray-900">${escapeHtml(title)}</h2>
                        ${subtitle ? `<p class="text-sm text-gray-500 mt-0.5">${escapeHtml(subtitle)}</p>` : ""}
                    </header>
                    <div class="p-4">${content}</div>
                </article>
            `;
        },

        table(headers, bodyId, caption = "") {
            return `
                <div class="overflow-x-auto">
                    <table class="w-full">
                        ${caption ? `<caption class="sr-only">${escapeHtml(caption)}</caption>` : ""}
                        <thead class="bg-gray-50 border-b border-gray-200">
                            <tr>
                                ${headers.map(h => `<th scope="col" class="px-4 py-3 text-left text-xs font-semibold text-gray-600 uppercase tracking-wider">${escapeHtml(h)}</th>`).join("")}
                            </tr>
                        </thead>
                        <tbody id="${bodyId}" class="divide-y divide-gray-100"></tbody>
                    </table>
                </div>
            `;
        },

        statCard(label, value, trend = null, colorClass = "") {
            return `
                <div class="flex items-center justify-between py-2">
                    <span class="text-sm text-gray-600">${label}</span>
                    <span class="font-semibold ${colorClass}">${escapeHtml(String(value))}</span>
                </div>
            `;
        },

        sectionTitle(title, tag = null) {
            return `
                <h3 class="font-medium text-gray-900 mb-3 flex items-center gap-2">
                    ${escapeHtml(title)}
                    ${tag ? `<span class="text-xs bg-${tag.color}-100 text-${tag.color}-700 px-2 py-0.5 rounded font-normal">${escapeHtml(tag.text)}</span>` : ""}
                </h3>
            `;
        },
    };

    // ==========================================================================
    // Template Generators
    // ==========================================================================

    const Templates = {
        tabButtons() {
            return CONFIG.tabs.map(tab => `
                <button
                    type="button"
                    class="tab-btn py-4 px-1 text-sm font-medium text-gray-500 hover:text-gray-700 border-b-2 border-transparent transition-colors ${state.currentTab === tab.id ? "border-blue-500 text-blue-600" : ""}"
                    data-tab="${tab.id}"
                    role="tab"
                    aria-selected="${state.currentTab === tab.id}"
                    aria-controls="panel-${tab.id}">
                    ${escapeHtml(tab.label)}
                </button>
            `).join("");
        },

        dashboard() {
            return `
                <section id="panel-dashboard" class="tab-panel" role="tabpanel" aria-labelledby="tab-dashboard">
                    <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
                        <article class="bg-white rounded-lg shadow-sm border border-gray-200 p-5">
                            <h3 class="text-sm font-semibold text-gray-700 mb-4 flex items-center gap-2">
                                <svg class="w-4 h-4 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"/>
                                </svg>
                                ステータス別タスク
                            </h3>
                            <div id="tasksByStatus" class="space-y-2">${UI.loading()}</div>
                        </article>

                        <article class="bg-white rounded-lg shadow-sm border border-gray-200 p-5">
                            <h3 class="text-sm font-semibold text-gray-700 mb-4 flex items-center gap-2">
                                <svg class="w-4 h-4 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19.428 15.428a2 2 0 00-1.022-.547l-2.387-.477a6 6 0 00-3.86.517l-.318.158a6 6 0 01-3.86.517L6.05 15.21a2 2 0 00-1.806.547M8 4h8l-1 1v5.172a2 2 0 00.586 1.414l5 5c1.26 1.26.367 3.414-1.415 3.414H4.828c-1.782 0-2.674-2.154-1.414-3.414l5-5A2 2 0 009 10.172V5L8 4z"/>
                                </svg>
                                設備別タスク
                            </h3>
                            <div id="tasksByEquipment" class="space-y-2 max-h-48 overflow-y-auto">${UI.loading()}</div>
                        </article>

                        <article class="bg-white rounded-lg shadow-sm border border-gray-200 p-5">
                            <h3 class="text-sm font-semibold text-gray-700 mb-4 flex items-center gap-2">
                                <svg class="w-4 h-4 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/>
                                </svg>
                                在庫不足の部品
                            </h3>
                            <div id="lowStockParts" class="space-y-2">${UI.loading()}</div>
                        </article>
                    </div>
                </section>
            `;
        },

        tasks() {
            return `
                <section id="panel-tasks" class="tab-panel hidden" role="tabpanel" aria-labelledby="tab-tasks">
                    <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
                        <aside class="lg:col-span-1">
                            <article class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
                                <header class="px-4 py-3 border-b border-gray-100 bg-gray-50/50">
                                    <h2 class="font-semibold text-gray-900">タスク一覧</h2>
                                </header>
                                <div id="taskList" class="divide-y divide-gray-100 max-h-[calc(100vh-280px)] overflow-y-auto">
                                    ${UI.loading()}
                                </div>
                            </article>
                        </aside>

                        <main class="lg:col-span-2">
                            <article class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
                                <header class="px-4 py-3 border-b border-gray-100 bg-gray-50/50">
                                    <h2 class="font-semibold text-gray-900">タスク詳細</h2>
                                </header>
                                <div id="taskDetails" class="p-4">
                                    ${UI.empty("左側のリストからタスクを選択してください", "inbox")}
                                </div>
                            </article>
                        </main>
                    </div>
                </section>
            `;
        },

        equipments() {
            return `
                <section id="panel-equipments" class="tab-panel hidden" role="tabpanel" aria-labelledby="tab-equipments">
                    <article class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
                        <header class="px-4 py-3 border-b border-gray-100 bg-gray-50/50">
                            <h2 class="font-semibold text-gray-900">設備一覧</h2>
                            <p class="text-sm text-gray-500 mt-0.5">親子階層構造で表示</p>
                        </header>
                        <div id="equipmentList" class="divide-y divide-gray-100">${UI.loading()}</div>
                    </article>
                </section>
            `;
        },

        parts() {
            return `
                <section id="panel-parts" class="tab-panel hidden" role="tabpanel" aria-labelledby="tab-parts">
                    <article class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
                        <header class="px-4 py-3 border-b border-gray-100 bg-gray-50/50">
                            <h2 class="font-semibold text-gray-900">部品一覧</h2>
                        </header>
                        ${UI.table(
                            ["名前", "型番", "保管場所", "在庫数", "発注点", "状態", "関連設備"],
                            "partsList",
                            "部品一覧テーブル"
                        )}
                    </article>
                </section>
            `;
        },

        customFields() {
            return `
                <section id="panel-custom-fields" class="tab-panel hidden" role="tabpanel" aria-labelledby="tab-custom-fields">
                    <article class="bg-white rounded-lg shadow-sm border border-gray-200 overflow-hidden">
                        <header class="px-4 py-3 border-b border-gray-100 bg-gray-50/50">
                            <h2 class="font-semibold text-gray-900">テナント独自入力項目</h2>
                            <p class="text-sm text-gray-500 mt-0.5">EAVパターンで実装されたカスタムフィールド定義</p>
                        </header>
                        ${UI.table(
                            ["項目名", "データ型", "必須", "表示順", "選択肢"],
                            "customFieldsList",
                            "カスタムフィールド一覧テーブル"
                        )}
                    </article>
                </section>
            `;
        },

        taskItem(task) {
            const isSelected = state.selectedTaskId === task.id;
            return `
                <article
                    class="p-4 cursor-pointer transition-colors ${isSelected ? "bg-blue-50 border-l-2 border-blue-500" : "hover:bg-gray-50"}"
                    data-task-id="${task.id}"
                    role="button"
                    tabindex="0"
                    aria-selected="${isSelected}">
                    <div class="flex items-start justify-between gap-2 mb-2">
                        <h3 class="font-medium text-gray-900 line-clamp-1">${escapeHtml(task.title)}</h3>
                        ${UI.statusBadge(task.status)}
                    </div>
                    <div class="flex flex-wrap gap-1 mb-2">
                        ${UI.priorityBadge(task.priority)}
                        ${UI.categoryBadge(task.category)}
                    </div>
                    <p class="text-sm text-gray-500">${escapeHtml(task.equipment_name || "")}</p>
                    ${task.assigned_to ? `<p class="text-xs text-gray-400 mt-1">担当: ${escapeHtml(task.assigned_to)}</p>` : ""}
                    ${task.due_date ? `<p class="text-xs text-gray-400">期日: ${formatDate(task.due_date)}</p>` : ""}
                </article>
            `;
        },

        taskDetails(data) {
            const { task: t, custom_fields = [], parts = [], comments = [] } = data;
            return `
                <div class="space-y-6">
                    <header>
                        <div class="flex flex-wrap items-center gap-2 mb-3">
                            <h3 class="text-xl font-bold text-gray-900">${escapeHtml(t.title)}</h3>
                            ${UI.statusBadge(t.status)}
                            ${UI.priorityBadge(t.priority)}
                            ${UI.categoryBadge(t.category)}
                        </div>
                        <p class="text-gray-600">${escapeHtml(t.description) || "説明なし"}</p>
                    </header>

                    <dl class="grid grid-cols-2 md:grid-cols-4 gap-4 p-4 bg-gray-50 rounded-lg">
                        <div>
                            <dt class="text-xs text-gray-500 mb-1">設備</dt>
                            <dd class="font-medium text-gray-900">${escapeHtml(t.equipment_name) || "-"}</dd>
                        </div>
                        <div>
                            <dt class="text-xs text-gray-500 mb-1">期日</dt>
                            <dd class="font-medium text-gray-900">${formatDate(t.due_date)}</dd>
                        </div>
                        <div>
                            <dt class="text-xs text-gray-500 mb-1">担当者</dt>
                            <dd class="font-medium text-gray-900">${escapeHtml(t.assigned_to) || "-"}</dd>
                        </div>
                        <div>
                            <dt class="text-xs text-gray-500 mb-1">作成日</dt>
                            <dd class="font-medium text-gray-900">${formatDateTime(t.created_at)}</dd>
                        </div>
                    </dl>

                    ${custom_fields.length > 0 ? `
                        <section aria-labelledby="custom-fields-heading">
                            ${UI.sectionTitle("テナント独自入力項目", { text: "EAV", color: "purple" })}
                            <dl class="space-y-2">
                                ${custom_fields.map(cf => `
                                    <div class="flex border-b border-gray-100 pb-2">
                                        <dt class="text-sm text-gray-500 w-1/3">${escapeHtml(cf.field_name)}</dt>
                                        <dd class="text-sm font-medium text-gray-900">${escapeHtml(cf.value) || "-"}</dd>
                                    </div>
                                `).join("")}
                            </dl>
                        </section>
                    ` : ""}

                    ${parts.length > 0 ? `
                        <section aria-labelledby="parts-heading">
                            ${UI.sectionTitle("使用部品")}
                            <ul class="space-y-2">
                                ${parts.map(p => `
                                    <li class="flex justify-between items-center p-3 bg-gray-50 rounded-lg">
                                        <div>
                                            <span class="font-medium text-gray-900">${escapeHtml(p.name)}</span>
                                            ${p.part_number ? `<span class="text-xs text-gray-500 ml-2">${escapeHtml(p.part_number)}</span>` : ""}
                                        </div>
                                        <span class="text-sm text-gray-600">数量: <strong>${p.quantity}</strong></span>
                                    </li>
                                `).join("")}
                            </ul>
                        </section>
                    ` : ""}

                    <section aria-labelledby="comments-heading">
                        ${UI.sectionTitle("コメント", { text: "課題2", color: "blue" })}
                        ${comments.length > 0 ? `
                            <ul class="space-y-3">
                                ${comments.map(c => `
                                    <li class="border-l-2 border-blue-300 pl-3 py-2">
                                        <div class="flex justify-between items-center mb-1">
                                            <span class="font-medium text-sm text-gray-900">${escapeHtml(c.commented_by)}</span>
                                            <time class="text-xs text-gray-400" datetime="${c.created_at}">${formatDateTime(c.created_at)}</time>
                                        </div>
                                        <p class="text-sm text-gray-600">${escapeHtml(c.comment)}</p>
                                    </li>
                                `).join("")}
                            </ul>
                        ` : UI.empty("コメントはまだありません")}
                    </section>
                </div>
            `;
        },

        equipmentItem(equipment) {
            const indent = equipment.depth * 1.5;
            return `
                <article class="p-4 hover:bg-gray-50 transition-colors" style="padding-left: calc(1rem + ${indent}rem)">
                    <div class="flex items-start gap-2">
                        ${equipment.depth > 0 ? '<span class="text-gray-300 mt-0.5">└</span>' : ""}
                        <div class="flex-1 min-w-0">
                            <div class="flex items-center justify-between gap-2">
                                <h3 class="font-medium text-gray-900 truncate">${escapeHtml(equipment.name)}</h3>
                                ${equipment.manufacturer ? `<span class="text-xs text-gray-400 shrink-0">製造元: ${escapeHtml(equipment.manufacturer)}</span>` : ""}
                            </div>
                            ${equipment.description ? `<p class="text-sm text-gray-500 mt-1">${escapeHtml(equipment.description)}</p>` : ""}
                        </div>
                    </div>
                </article>
            `;
        },

        partRow(part) {
            const isLow = part.stock_quantity <= part.reorder_point;
            return `
                <tr class="hover:bg-gray-50 transition-colors">
                    <td class="px-4 py-3">
                        <div class="font-medium text-gray-900">${escapeHtml(part.name)}</div>
                        ${part.description ? `<div class="text-xs text-gray-400 mt-0.5 line-clamp-1">${escapeHtml(part.description)}</div>` : ""}
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-600">${escapeHtml(part.part_number) || "-"}</td>
                    <td class="px-4 py-3 text-sm text-gray-600">${escapeHtml(part.location) || "-"}</td>
                    <td class="px-4 py-3 text-sm ${isLow ? "text-red-600 font-semibold" : "text-gray-900"}">${part.stock_quantity}</td>
                    <td class="px-4 py-3 text-sm text-gray-600">${part.reorder_point}</td>
                    <td class="px-4 py-3">
                        ${UI.badge(isLow ? "要発注" : "OK", isLow ? "bg-red-100 text-red-700 border-red-200" : "bg-emerald-100 text-emerald-700 border-emerald-200")}
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-500 max-w-xs truncate">${escapeHtml(part.related_equipments) || "-"}</td>
                </tr>
            `;
        },

        customFieldRow(field) {
            let options = "-";
            if (field.options) {
                try {
                    options = JSON.parse(field.options).join(", ");
                } catch {
                    options = field.options;
                }
            }
            return `
                <tr class="hover:bg-gray-50 transition-colors">
                    <td class="px-4 py-3 font-medium text-gray-900">${escapeHtml(field.field_name)}</td>
                    <td class="px-4 py-3">${UI.fieldTypeBadge(field.field_type)}</td>
                    <td class="px-4 py-3">
                        ${field.is_required
                            ? '<span class="text-red-500 font-medium">必須</span>'
                            : '<span class="text-gray-400">-</span>'}
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-600">${field.display_order}</td>
                    <td class="px-4 py-3 text-sm text-gray-500">${escapeHtml(options)}</td>
                </tr>
            `;
        },
    };

    // ==========================================================================
    // Data Loading Functions
    // ==========================================================================

    async function loadTenants() {
        const select = $id("tenantSelect");
        if (!select) return;

        try {
            const tenants = await fetchApi(CONFIG.api.tenants, { loadingKey: "tenants" });
            select.innerHTML = tenants
                .map(t => `<option value="${t.id}">${escapeHtml(t.name)}</option>`)
                .join("");

            if (tenants.length > 0) {
                state.currentTenant = tenants[0].id;
                loadAllData();
            }
        } catch {
            select.innerHTML = '<option value="">読み込みエラー</option>';
        }
    }

    function loadAllData() {
        if (!state.currentTenant) return;
        loadStats();
        loadTasks();
        loadEquipments();
        loadParts();
        loadCustomFields();
    }

    async function loadStats() {
        const statusEl = $id("tasksByStatus");
        const equipmentEl = $id("tasksByEquipment");
        const partsEl = $id("lowStockParts");

        try {
            const stats = await fetchApi(
                CONFIG.api.stats(state.currentTenant),
                { loadingKey: "stats" }
            );

            if (statusEl) {
                statusEl.innerHTML = stats.tasks_by_status?.length > 0
                    ? stats.tasks_by_status.map(s =>
                        UI.statCard(UI.statusBadge(s.status), s.count)
                    ).join("")
                    : UI.empty("タスクなし");
            }

            if (equipmentEl) {
                equipmentEl.innerHTML = stats.tasks_by_equipment?.length > 0
                    ? stats.tasks_by_equipment.map(e =>
                        UI.statCard(`<span class="truncate">${escapeHtml(e.name)}</span>`, e.count)
                    ).join("")
                    : UI.empty("設備なし");
            }

            if (partsEl) {
                partsEl.innerHTML = stats.low_stock_parts?.length > 0
                    ? stats.low_stock_parts.map(p =>
                        UI.statCard(
                            escapeHtml(p.name),
                            `<span class="text-red-600">${p.stock_quantity}/${p.reorder_point}</span>`
                        )
                    ).join("")
                    : `<p class="text-emerald-600 text-sm text-center py-4">在庫は十分です</p>`;
            }
        } catch {
            [statusEl, equipmentEl, partsEl].forEach(el => {
                if (el) el.innerHTML = UI.empty("読み込みエラー");
            });
        }
    }

    async function loadTasks() {
        const container = $id("taskList");
        if (!container) return;

        try {
            const response = await fetchApi(
                CONFIG.api.tasks(state.currentTenant),
                { loadingKey: "tasks" }
            );
            const tasks = response.items || response;

            container.innerHTML = tasks.length > 0
                ? tasks.map(Templates.taskItem).join("")
                : UI.empty("タスクがありません");

            bindTaskListEvents();
        } catch {
            container.innerHTML = UI.empty("読み込みエラー");
        }
    }

    async function loadTaskDetails(taskId) {
        const container = $id("taskDetails");
        if (!container) return;

        state.selectedTaskId = taskId;
        container.innerHTML = UI.loading();

        // Update selected state in list
        $$("[data-task-id]").forEach(el => {
            const isSelected = el.dataset.taskId === taskId;
            el.classList.toggle("bg-blue-50", isSelected);
            el.classList.toggle("border-l-2", isSelected);
            el.classList.toggle("border-blue-500", isSelected);
            el.setAttribute("aria-selected", isSelected);
        });

        try {
            const data = await fetchApi(
                CONFIG.api.taskDetails(taskId),
                { loadingKey: "taskDetails" }
            );
            container.innerHTML = Templates.taskDetails(data);
        } catch {
            container.innerHTML = UI.empty("読み込みエラー");
        }
    }

    async function loadEquipments() {
        const container = $id("equipmentList");
        if (!container) return;

        try {
            const response = await fetchApi(
                CONFIG.api.equipments(state.currentTenant),
                { loadingKey: "equipments" }
            );
            const equipments = response.items || response;

            container.innerHTML = equipments.length > 0
                ? equipments.map(Templates.equipmentItem).join("")
                : UI.empty("設備がありません");
        } catch {
            container.innerHTML = UI.empty("読み込みエラー");
        }
    }

    async function loadParts() {
        const container = $id("partsList");
        if (!container) return;

        try {
            const response = await fetchApi(
                CONFIG.api.parts(state.currentTenant),
                { loadingKey: "parts" }
            );
            const parts = response.items || response;

            container.innerHTML = parts.length > 0
                ? parts.map(Templates.partRow).join("")
                : `<tr><td colspan="7" class="px-4 py-8 text-center text-gray-400">部品がありません</td></tr>`;
        } catch {
            container.innerHTML = `<tr><td colspan="7" class="px-4 py-8 text-center text-gray-400">読み込みエラー</td></tr>`;
        }
    }

    async function loadCustomFields() {
        const container = $id("customFieldsList");
        if (!container) return;

        try {
            const fields = await fetchApi(
                CONFIG.api.customFields(state.currentTenant),
                { loadingKey: "customFields" }
            );

            container.innerHTML = fields.length > 0
                ? fields.map(Templates.customFieldRow).join("")
                : `<tr><td colspan="5" class="px-4 py-8 text-center text-gray-400">独自入力項目がありません</td></tr>`;
        } catch {
            container.innerHTML = `<tr><td colspan="5" class="px-4 py-8 text-center text-gray-400">読み込みエラー</td></tr>`;
        }
    }

    // ==========================================================================
    // Event Handlers
    // ==========================================================================

    function bindTaskListEvents() {
        const container = $id("taskList");
        if (!container) return;

        container.addEventListener("click", (e) => {
            const taskEl = e.target.closest("[data-task-id]");
            if (taskEl) {
                loadTaskDetails(taskEl.dataset.taskId);
            }
        });

        container.addEventListener("keydown", (e) => {
            if (e.key === "Enter" || e.key === " ") {
                const taskEl = e.target.closest("[data-task-id]");
                if (taskEl) {
                    e.preventDefault();
                    loadTaskDetails(taskEl.dataset.taskId);
                }
            }
        });
    }

    function showTab(tabId) {
        state.currentTab = tabId;

        $$(".tab-panel").forEach(panel => {
            panel.classList.add("hidden");
        });

        $$(".tab-btn").forEach(btn => {
            const isActive = btn.dataset.tab === tabId;
            btn.classList.toggle("border-blue-500", isActive);
            btn.classList.toggle("text-blue-600", isActive);
            btn.classList.toggle("border-transparent", !isActive);
            btn.classList.toggle("text-gray-500", !isActive);
            btn.setAttribute("aria-selected", isActive);
        });

        const panel = $id(`panel-${tabId}`);
        if (panel) {
            panel.classList.remove("hidden");
        }
    }

    function bindGlobalEvents() {
        // Tenant select
        const tenantSelect = $id("tenantSelect");
        if (tenantSelect) {
            tenantSelect.addEventListener("change", (e) => {
                state.currentTenant = e.target.value;
                state.selectedTaskId = null;
                state.cache.clear();
                loadAllData();
            });
        }

        // Tab buttons (using event delegation)
        const tabContainer = $id("tabButtons");
        if (tabContainer) {
            tabContainer.addEventListener("click", (e) => {
                const btn = e.target.closest(".tab-btn");
                if (btn) {
                    showTab(btn.dataset.tab);
                }
            });
        }

        // Keyboard navigation for tabs
        document.addEventListener("keydown", (e) => {
            if (e.target.classList.contains("tab-btn")) {
                const tabs = Array.from($$(".tab-btn"));
                const currentIndex = tabs.indexOf(e.target);

                let newIndex = currentIndex;
                if (e.key === "ArrowLeft") {
                    newIndex = currentIndex > 0 ? currentIndex - 1 : tabs.length - 1;
                } else if (e.key === "ArrowRight") {
                    newIndex = currentIndex < tabs.length - 1 ? currentIndex + 1 : 0;
                }

                if (newIndex !== currentIndex) {
                    e.preventDefault();
                    tabs[newIndex].focus();
                    showTab(tabs[newIndex].dataset.tab);
                }
            }
        });
    }

    // ==========================================================================
    // Initialization
    // ==========================================================================

    function initializeUI() {
        const tabButtons = $id("tabButtons");
        const mainContent = $id("mainContent");

        if (tabButtons) {
            tabButtons.innerHTML = Templates.tabButtons();
        }

        if (mainContent) {
            mainContent.innerHTML = `
                ${Templates.dashboard()}
                ${Templates.tasks()}
                ${Templates.equipments()}
                ${Templates.parts()}
                ${Templates.customFields()}
            `;
        }
    }

    function initialize() {
        initializeUI();
        bindGlobalEvents();
        loadTenants();
    }

    // Start application when DOM is ready
    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", initialize);
    } else {
        initialize();
    }

    // Expose necessary functions to global scope for debugging
    window.M2X = {
        state,
        showTab,
        loadAllData,
        loadTaskDetails,
    };
})();
