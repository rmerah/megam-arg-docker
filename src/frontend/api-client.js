/**
 * API Client for ARG Pipeline Backend
 *
 * Auto-détection de l'URL de base:
 * - Reverse proxy (port 80/443): URL relative
 * - Développement local: backend sur port frontend - 80
 *   (ex: frontend 8080 → backend 8000, frontend 8082 → backend 8002)
 *
 * Functions:
 * - launchJob(sampleId, options)
 * - getStatus(jobId)
 * - getResults(jobId)
 * - listJobs(filters)
 */

// Auto-détection de l'URL de l'API
const API_BASE_URL = (() => {
    const port = window.location.port;
    if (!port || port === '80' || port === '443') return '';
    // Mode développement : backend sur port frontend - 80
    const backendPort = parseInt(port, 10) - 80;
    return `http://${window.location.hostname}:${backendPort}`;
})();

/**
 * Vérifie la connexion au backend et affiche un bandeau si injoignable
 */
async function checkBackendConnection() {
    try {
        const controller = new AbortController();
        setTimeout(() => controller.abort(), 30000);
        const response = await fetch(`${API_BASE_URL}/api/databases`, {
            signal: controller.signal,
            headers: { 'Cache-Control': 'no-cache' }
        });
        if (response.ok) {
            _removeConnectionBanner();
            return true;
        }
    } catch (e) { /* ignore */ }
    _showConnectionBanner();
    return false;
}

function _showConnectionBanner() {
    if (document.getElementById('backend-connection-banner')) return;
    const banner = document.createElement('div');
    banner.id = 'backend-connection-banner';
    banner.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:9999;background:#FEF2F2;border-bottom:2px solid #EF4444;padding:12px 24px;display:flex;align-items:center;justify-content:center;gap:12px;font-family:Inter,sans-serif;';
    banner.innerHTML = `
        <span style="font-size:20px">⚠️</span>
        <span style="color:#991B1B;font-weight:600;font-size:14px">
            Backend API non disponible sur <code style="background:#FEE2E2;padding:2px 6px;border-radius:4px">${API_BASE_URL || window.location.origin}</code>
        </span>
        <span style="color:#B91C1C;font-size:13px">
            — Lancez le backend : <code style="background:#FEE2E2;padding:2px 6px;border-radius:4px">cd backend && source venv/bin/activate && python -m uvicorn main:app --host 0.0.0.0 --port ${new URL(API_BASE_URL || window.location.origin).port || '8000'}</code>
        </span>
        <button onclick="this.parentElement.remove();checkBackendConnection()" style="margin-left:12px;background:#EF4444;color:white;border:none;padding:4px 12px;border-radius:4px;cursor:pointer;font-size:12px">Réessayer</button>
    `;
    document.body.prepend(banner);
}

function _removeConnectionBanner() {
    const banner = document.getElementById('backend-connection-banner');
    if (banner) banner.remove();
}

/**
 * Launch a new analysis job
 * @param {string} sampleId - Sample identifier (SRR*, CP*, GCA*, or local file path)
 * @param {Object} options - Job configuration
 * @param {number} options.threads - Number of threads (default: 8)
 * @param {string} options.prokka_mode - Prokka mode: auto, generic, ecoli, custom (default: auto)
 * @param {boolean} options.force - Force re-run if exists (default: false)
 * @returns {Promise<Object>} Job response with job_id, status, etc.
 */
async function launchJob(sampleId, options = {}) {
    const {
        threads = 8,
        prokka_mode = 'auto',
        force = false
    } = options;

    try {
        const response = await fetch(`${API_BASE_URL}/api/launch`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                sample_id: sampleId,
                threads: threads,
                prokka_mode: prokka_mode,
                force: force
            })
        });

        if (!response.ok) {
            const errorData = await response.json();
            throw new Error(errorData.detail || `HTTP error ${response.status}`);
        }

        return await response.json();
    } catch (error) {
        console.error('Error launching job:', error);
        throw error;
    }
}

/**
 * Get status of a running or completed job
 * @param {string} jobId - Job UUID
 * @returns {Promise<Object>} Job status with progress, current_step, logs, etc.
 */
async function getStatus(jobId) {
    try {
        // Add no-cache headers to force fresh data
        const response = await fetch(`${API_BASE_URL}/api/status/${jobId}`, {
            cache: 'no-cache',
            headers: {
                'Cache-Control': 'no-cache, no-store, must-revalidate',
                'Pragma': 'no-cache',
                'Expires': '0'
            }
        });

        if (!response.ok) {
            const errorData = await response.json();
            throw new Error(errorData.detail || `HTTP error ${response.status}`);
        }

        return await response.json();
    } catch (error) {
        console.error('Error fetching status:', error);
        throw error;
    }
}

/**
 * Get results of a completed job
 * @param {string} jobId - Job UUID
 * @returns {Promise<Object>} Results with assembly_stats, arg_detection, etc.
 */
async function getResults(jobId) {
    try {
        const response = await fetch(`${API_BASE_URL}/api/results/${jobId}`);

        if (!response.ok) {
            const errorData = await response.json();
            throw new Error(errorData.detail || `HTTP error ${response.status}`);
        }

        return await response.json();
    } catch (error) {
        console.error('Error fetching results:', error);
        throw error;
    }
}

/**
 * List all jobs with optional filters
 * @param {Object} filters - Query filters
 * @param {string} filters.status_filter - Filter by status: PENDING, RUNNING, COMPLETED, FAILED
 * @param {number} filters.limit - Max number of results (default: 100)
 * @param {number} filters.offset - Pagination offset (default: 0)
 * @returns {Promise<Object>} List of jobs with total count
 */
async function listJobs(filters = {}) {
    const {
        status_filter,
        limit = 100,
        offset = 0
    } = filters;

    try {
        const params = new URLSearchParams();
        if (status_filter) params.append('status_filter', status_filter);
        params.append('limit', limit.toString());
        params.append('offset', offset.toString());

        const response = await fetch(`${API_BASE_URL}/api/jobs?${params}`);

        if (!response.ok) {
            const errorData = await response.json();
            throw new Error(errorData.detail || `HTTP error ${response.status}`);
        }

        return await response.json();
    } catch (error) {
        console.error('Error listing jobs:', error);
        throw error;
    }
}

/**
 * Helper: Get job_id from URL query parameters
 * @param {string} paramName - Parameter name (default: 'job_id')
 * @returns {string|null} Job ID or null if not found
 */
function getJobIdFromUrl(paramName = 'job_id') {
    const urlParams = new URLSearchParams(window.location.search);
    return urlParams.get(paramName);
}

/**
 * Helper: Format timestamp to readable date
 * @param {string} timestamp - ISO timestamp
 * @returns {string} Formatted date string
 */
function formatTimestamp(timestamp) {
    if (!timestamp) return 'N/A';
    const date = new Date(timestamp);
    return date.toLocaleString('en-US', {
        year: 'numeric',
        month: 'short',
        day: 'numeric',
        hour: '2-digit',
        minute: '2-digit',
        second: '2-digit'
    });
}

/**
 * Helper: Format duration between two timestamps
 * @param {string} startTime - Start ISO timestamp
 * @param {string} endTime - End ISO timestamp (or null for current time)
 * @returns {string} Formatted duration (HH:MM:SS)
 */
function formatDuration(startTime, endTime = null) {
    if (!startTime) return '00:00:00';

    const start = new Date(startTime);
    const end = endTime ? new Date(endTime) : new Date();
    const diffSeconds = Math.floor((end - start) / 1000);

    const hours = Math.floor(diffSeconds / 3600);
    const minutes = Math.floor((diffSeconds % 3600) / 60);
    const seconds = diffSeconds % 60;

    return `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
}

/**
 * Helper: Get status badge HTML
 * @param {string} status - Job status (PENDING, RUNNING, COMPLETED, FAILED)
 * @returns {string} HTML string for status badge
 */
function getStatusBadge(status) {
    const badges = {
        'PENDING': '<span class="badge" style="border-color: #78716C; color: #78716C; background: #F5F5F4;">PENDING</span>',
        'RUNNING': '<span class="badge" style="border-color: #1E3A8A; color: #1E3A8A; background: #DBEAFE;">RUNNING</span>',
        'COMPLETED': '<span class="badge badge-success">COMPLETED</span>',
        'FAILED': '<span class="badge badge-error">FAILED</span>'
    };
    return badges[status] || `<span class="badge">${status}</span>`;
}

/**
 * Helper: Escape HTML to prevent XSS
 * @param {string} text - Text to escape
 * @returns {string} Escaped HTML string
 */
function escapeHtml(text) {
    if (text === null || text === undefined) return '';
    const div = document.createElement('div');
    div.textContent = String(text);
    return div.innerHTML;
}

// Export functions for use in HTML pages
// Note: In production, use ES6 modules instead
if (typeof window !== 'undefined') {
    window.ARGPipelineAPI = {
        launchJob,
        getStatus,
        getResults,
        listJobs,
        getJobIdFromUrl,
        formatTimestamp,
        formatDuration,
        getStatusBadge,
        escapeHtml
    };
}
