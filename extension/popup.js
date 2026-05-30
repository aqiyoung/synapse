// Synapse - popup 脚本
(function() {
  const DEFAULT_TAGS = ['网页', '待整理'];
  let selectedTags = new Set(['网页']);

  // 初始化
  document.addEventListener('DOMContentLoaded', async () => {
    renderTags();
    loadSettings();
    detectPage();

    document.getElementById('clipBtn').addEventListener('click', clipPage);
    document.getElementById('customTag').addEventListener('keydown', (e) => {
      if (e.key === 'Enter') addCustomTag();
    });
    document.getElementById('openWiki').addEventListener('click', (e) => {
      e.preventDefault();
      const url = document.getElementById('apiUrl').value.trim();
      const wikiUrl = url.includes('18800') ? url.replace('18800', '18800') : url;
      chrome.tabs.create({ url: wikiUrl });
    });
  });

  function renderTags() {
    const el = document.getElementById('tags');
    el.innerHTML = '';
    for (const tag of DEFAULT_TAGS) {
      const span = document.createElement('span');
      span.className = 'tag' + (selectedTags.has(tag) ? ' on' : '');
      span.textContent = tag;
      span.addEventListener('click', () => {
        if (selectedTags.has(tag)) selectedTags.delete(tag);
        else selectedTags.add(tag);
        renderTags();
      });
      el.appendChild(span);
    }
  }

  function addCustomTag() {
    const input = document.getElementById('customTag');
    const val = input.value.trim();
    if (val) {
      selectedTags.add(val);
      // 动态添加标签按钮
      const el = document.getElementById('tags');
      const span = document.createElement('span');
      span.className = 'tag on';
      span.textContent = val;
      span.addEventListener('click', () => {
        selectedTags.delete(val);
        span.remove();
      });
      el.appendChild(span);
      input.value = '';
    }
  }

  function loadSettings() {
    chrome.storage.local.get(['apiUrl'], (res) => {
      if (res.apiUrl) document.getElementById('apiUrl').value = res.apiUrl;
    });
  }

  async function detectPage() {
    try {
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
      if (tab?.title) {
        document.getElementById('title').placeholder = tab.title;
        document.getElementById('pageInfo').textContent = tab.title.substring(0, 30) + (tab.title.length > 30 ? '...' : '');
      }
    } catch(e) {}
  }

  async function clipPage() {
    const btn = document.getElementById('clipBtn');
    const status = document.getElementById('status');
    btn.disabled = true;
    btn.textContent = '⏳ 提取中...';
    status.className = 'status';
    status.style.display = 'none';

    try {
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
      if (!tab?.id) throw new Error('无法获取当前标签页');

      // 注入 Readability + Turndown 提取正文
      const results = await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        func: extractArticle,
      });

      const article = results?.[0]?.result;
      if (!article?.content) throw new Error('无法提取页面内容');

      const title = document.getElementById('title').value.trim() || article.title || tab.title || '未命名';
      const tags = Array.from(selectedTags);
      const apiUrl = document.getElementById('apiUrl').value.trim();

      // 保存 API 地址
      chrome.storage.local.set({ apiUrl });

      btn.textContent = '📤 上传中...';

      // 上传到知识库
      const resp = await fetch(`${apiUrl}/api/notes`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ title, content: article.content, tags }),
      });

      if (!resp.ok) throw new Error(`上传失败: ${resp.status}`);

      const note = await resp.json();
      status.className = 'status ok';
      status.textContent = `✅ 已保存: #${note.id} ${note.title}`;
      status.style.display = 'block';
      btn.textContent = '📥 保存当前页面';
      btn.disabled = false;

    } catch(e) {
      status.className = 'status err';
      status.textContent = `❌ ${e.message}`;
      status.style.display = 'block';
      btn.textContent = '📥 保存当前页面';
      btn.disabled = false;
    }
  }

  // 在页面上下文中执行的提取函数
  function extractArticle() {
    // 简化版 Readability：提取主要文本内容
    function getArticleContent() {
      // 尝试常见的内容选择器
      const selectors = [
        'article',
        '[role="main"]',
        '.post-content',
        '.article-content',
        '.entry-content',
        '.content',
        'main',
        '#content',
      ];

      let container = null;
      for (const sel of selectors) {
        container = document.querySelector(sel);
        if (container) break;
      }

      if (!container) {
        // fallback: body 去掉 nav/header/footer/aside
        container = document.body.cloneNode(true);
        for (const el of container.querySelectorAll('nav, header, footer, aside, script, style, .nav, .sidebar, .menu, .footer, .header, .ad, .ads')) {
          el.remove();
        }
      }

      // 转 Markdown（简化版）
      function toMarkdown(el) {
        let md = '';
        for (const node of el.childNodes) {
          if (node.nodeType === 3) {
            md += node.textContent;
            continue;
          }
          if (node.nodeType !== 1) continue;
          const tag = node.tagName.toLowerCase();
          if (tag === 'br') { md += '\n'; continue; }
          if (tag === 'p' || tag === 'div') { md += '\n\n' + toMarkdown(node) + '\n\n'; continue; }
          if (tag === 'h1') { md += '\n\n# ' + toMarkdown(node) + '\n\n'; continue; }
          if (tag === 'h2') { md += '\n\n## ' + toMarkdown(node) + '\n\n'; continue; }
          if (tag === 'h3') { md += '\n\n### ' + toMarkdown(node) + '\n\n'; continue; }
          if (tag === 'h4') { md += '\n\n#### ' + toMarkdown(node) + '\n\n'; continue; }
          if (tag === 'ul') { md += '\n' + toMarkdown(node) + '\n'; continue; }
          if (tag === 'ol') { md += '\n' + toMarkdown(node) + '\n'; continue; }
          if (tag === 'li') { md += '- ' + toMarkdown(node).trim() + '\n'; continue; }
          if (tag === 'pre') { md += '\n\n```\n' + node.textContent + '\n```\n\n'; continue; }
          if (tag === 'code') { md += '`' + node.textContent + '`'; continue; }
          if (tag === 'a') { const href = node.getAttribute('href') || ''; md += '[' + toMarkdown(node) + '](' + href + ')'; continue; }
          if (tag === 'strong' || tag === 'b') { md += '**' + toMarkdown(node) + '**'; continue; }
          if (tag === 'em' || tag === 'i') { md += '*' + toMarkdown(node) + '*'; continue; }
          if (tag === 'img') { const src = node.getAttribute('src') || ''; const alt = node.getAttribute('alt') || ''; md += '![' + alt + '](' + src + ')'; continue; }
          if (tag === 'blockquote') { md += '\n\n> ' + toMarkdown(node).trim() + '\n\n'; continue; }
          if (tag === 'table') { md += '\n\n' + toMarkdown(node) + '\n\n'; continue; }
          if (tag === 'tr') { md += '| ' + Array.from(node.children).map(c => toMarkdown(c).trim()).join(' | ') + ' |\n'; continue; }
          if (tag === 'th' || tag === 'td') { md += toMarkdown(node); continue; }
          // 跳过 script/style
          if (tag === 'script' || tag === 'style') continue;
          md += toMarkdown(node);
        }
        return md;
      }

      const content = toMarkdown(container).replace(/\n{3,}/g, '\n\n').trim();
      return {
        title: document.title,
        content: content,
      };
    }

    return getArticleContent();
  }
})();
