// Link check for the module graph: every module must import under jsc (no
// top-level DOM access) and provide its contract exports.
import { test, expect, run } from './harness.js';

// ---------------------------------------------------------------------------
// MODULE LIST — integrator: extend this with EVERY .js module under src/.
// Format: [path relative to tests/, { exportName: 'function' | 'object' | 'string' | 'number' | 'any' }]
// ---------------------------------------------------------------------------
const MODULES = [
  // Windows app (2026-10-14): Karteikarten, Prüfung, Wiederholungsfragen, Serien, Töne, Tippen.
  ['../src/core/exam.js', { ACCEPTED_FORMS: 'object', ANSWER_WITH: 'object', COUNT_CHOICES: 'object', DEFAULT_EXAM_SETTINGS: 'object', LEAVE_CONFIRM: 'object', MINUTE_CHOICES: 'object', NOT_MASTERY_NOTE: 'string', ONE_MINUTE_MS: 'number', ONE_MINUTE_TEXT: 'string', SMALL_MISTAKES: 'object', SMALL_MISTAKES_ALLOWED: 'object', SMALL_MISTAKES_TEXT: 'string', STARRED_CAPTION: 'string', TIMED_OUT_LINE: 'string', TIMED_OUT_TOAST: 'string', TOLERANCES: 'object', answerDiff: 'function', answerFor: 'function', answerPlaceholder: 'function', answeredCount: 'function', answeredText: 'function', answeredTooltip: 'function', cardIdsToPractise: 'function', celebrates: 'function', clockState: 'function', clockText: 'function', closestDiff: 'function', countCaption: 'function', countChoiceLabel: 'function', countChoicesFor: 'function', countSelection: 'function', evaluateExam: 'function', examDeadline: 'function', examGrade: 'function', examScope: 'function', expectedLabel: 'function', gradeText: 'function', gradeTone: 'function', hasText: 'function', introText: 'function', isEmptyForExam: 'function', itemPointsLabel: 'function', itemPointsText: 'function', learnCardsPath: 'function', learnMistakesTooltip: 'function', makeQuestions: 'function', markAnswer: 'function', markBadge: 'function', markCount: 'function', markLabel: 'function', minorCaption: 'function', minorPoints: 'function', minuteChoiceLabel: 'function', minutesText: 'function', nearestChoice: 'function', noteTone: 'function', passes: 'function', plannedCount: 'function', pointsText: 'function', promptLabel: 'function', questionCard: 'function', questionCount: 'function', readExamSettings: 'function', resultAnnouncement: 'function', resultSubtitle: 'function', retakeMistakesTooltip: 'function', sameExamSettings: 'function', scoreLine: 'function', setupSummary: 'function', showsExpected: 'function', spokenTime: 'function', starredCount: 'function', starredLabel: 'function', startAnnouncement: 'function', submitConfirm: 'function', suggestedMinutes: 'function', timeCaption: 'function', toleranceText: 'function', toleranceTitle: 'function', updateExamSettings: 'function', verdict: 'function', warnsBeforeEnd: 'function' }],
  ['../src/core/flashcards.js', { FRONTS: 'object', KNOW: 'string', STILL_LEARNING: 'string', VERDICTS: 'object', canUndo: 'function', cardsLabel: 'function', currentCardId: 'function', deckPhase: 'function', deckStats: 'function', deckTotal: 'function', eligibleIds: 'function', finishedText: 'function', finishedTitle: 'function', flipCard: 'function', hasProgress: 'function', hasText: 'function', isConsistent: 'function', isResumable: 'function', keyAction: 'function', knownCount: 'function', knownInRound: 'function', knownShare: 'function', lastSort: 'function', learningCount: 'function', newDeck: 'function', nextRoundAction: 'function', orderedIds: 'function', parseDeck: 'function', restartDeck: 'function', restartMessage: 'function', roundDoneText: 'function', roundDoneTitle: 'function', runningDeck: 'function', runningDetail: 'function', sameDeck: 'function', setShuffled: 'function', showsTermSide: 'function', shuffledIds: 'function', sortCard: 'function', startNextRound: 'function', startingDeck: 'function', syncDeck: 'function', undoSort: 'function', upcomingIds: 'function', verdictTitle: 'function' }],
  ['../src/core/typeahead.js', { TYPE_AHEAD_MAX: 'number', TYPE_AHEAD_MIN_LETTERS: 'number', TYPING_IDLE: 'object', articlePrefixes: 'function', correctionHint: 'function', digitValue: 'function', moveHighlight: 'function', optionState: 'function', returnLabel: 'function', typeAhead: 'function', typingHint: 'function', typingKey: 'function' }],
  ['../src/lib/shortcuts.js', { commandKey: 'function', commandLetter: 'function', isComposingKey: 'function', isTypingTarget: 'function' }],
  ['../src/screens/answer-streak.js', { STREAK_MILESTONE_STEP: 'number', STREAK_START: 'object', STREAK_VISIBLE_FROM: 'number', bestStreakText: 'function', isStreakMilestone: 'function', overrideStreak: 'function', recordStreak: 'function', streakLabel: 'function', streakTitle: 'function', streakVisible: 'function' }],
  ['../src/screens/exam-results.js', { resultsView: 'function' }],
  ['../src/screens/exam-setup.js', { compactLabel: 'function', emptyView: 'function', examDock: 'function', examPill: 'function', setupView: 'function' }],
  ['../src/screens/exam-sheet.js', { createSheet: 'function', statusView: 'function', submitKeyLabel: 'function' }],
  ['../src/screens/exam.js', { render: 'function' }],
  ['../src/screens/flashcards-card.js', { MOTION: 'object', STACK: 'object', cardHeightFor: 'function', cardTextSize: 'function', createCardStage: 'function', cubicBezier: 'function', glideAt: 'function', glideTransform: 'function', sampledFrames: 'function', turnAt: 'function', turnTransform: 'function' }],
  ['../src/screens/flashcards-keys.js', { bindFlashcardKeys: 'function', commandFor: 'function' }],
  ['../src/screens/flashcards-swipe.js', { SWIPE: 'object', armedVerdict: 'function', bindSwipe: 'function', createSwipeTracker: 'function', swipeLean: 'function', swipeOffset: 'function', swipeVerdict: 'function' }],
  ['../src/screens/flashcards-views.js', { backspaceText: 'function', createActionBar: 'function', createFlashcardsSidebar: 'function', emptyView: 'function', openFlashcardsOptions: 'function', shortcutText: 'function', summaryView: 'function' }],
  ['../src/screens/flashcards.js', { render: 'function' }],
  ['../src/screens/learn-start.js', { REPLACE_CONFIRM: 'string', REPLACE_TITLE: 'string', replaceLearnPrompt: 'function', startLearnWithCards: 'function' }],
  ['../src/screens/set-model.js', { DIFFICULT_MISTAKES: 'number', difficultCards: 'function', mistakesOf: 'function', setPageCommand: 'function' }],
  ['../src/ui/daily-streak.js', { CELEBRATE_DELAY_MS: 'number', CELEBRATE_TOAST_MS: 'number', celebrationMessage: 'function', createStreakIndicator: 'function', msUntilMidnight: 'function', shouldCelebrate: 'function', streakCaption: 'function', streakTitle: 'function', streakTone: 'function', streakTooltip: 'function', watchDailyStreak: 'function' }],
  // W1 foundation
  ['../src/main.js', {}],
  ['../src/lib/host.js', { isDesktopApp: 'function', reportTheme: 'function', reportUnsaved: 'function', limitContextMenu: 'function', blockNewWindows: 'function', opensNewWindow: 'function' }],
  ['../src/lib/prefs.js', { PREF: 'object', getPref: 'function', setPref: 'function', onPrefChange: 'function' }],
  ['../src/lib/sounds.js', { SOUNDS: 'object', SAMPLE_RATE: 'number', renderSound: 'function', playSound: 'function', soundEffectsEnabled: 'function', setSoundEffectsEnabled: 'function', studyStepSound: 'function', playStudyStep: 'function' }],
  ['../src/router.js', { startRouter: 'function', navigate: 'function', currentRoute: 'function', setLeaveGuard: 'function', setTitle: 'function', parsePath: 'function', href: 'function' }],
  ['../src/lib/dom.js', { h: 'function', clear: 'function', $: 'function', $$: 'function', on: 'function', focusFirst: 'function', replayClass: 'function', FOCUSABLE: 'string', isVisible: 'function', focusableWithin: 'function', prefersReducedMotion: 'function', $: 'function', $$: 'function', setTextAttrs: 'function' }],
  ['../src/lib/id.js', { uid: 'function' }],
  ['../src/lib/time.js', { dateKey: 'function', relativeTime: 'function', formatDuration: 'function', formatDate: 'function', calendarDaysBetween: 'function' }],
  ['../src/lib/labels.js', { LANGS: 'object', LANG_ORDER: 'object', STATUS: 'object', NOTE_LABELS: 'object', HINT_LABELS: 'object', plural: 'function', langName: 'function', langShort: 'function', langPair: 'function', bcp47: 'function', textAttrs: 'function', fieldAttrs: 'function' }],
  ['../src/lib/speech.js', { canSpeak: 'function', speak: 'function', stopSpeaking: 'function', automaticVoiceLabel: 'function', onVoicesChanged: 'function', preferredVoiceId: 'function', primeVoices: 'function', rankVoices: 'function', setMissingVoiceHandler: 'function', setPreferredVoice: 'function', speakable: 'function', voiceLabel: 'function', voiceOptions: 'function', voiceSample: 'function', voicesLoaded: 'function' }],
  ['../src/lib/keyboard.js', { SPECIAL_CHARS: 'object', charsFor: 'function', insertAtCaret: 'function' }],
  ['../src/lib/theme.js', { applyTheme: 'function', initTheme: 'function', resolveTheme: 'function', getThemeSetting: 'function' }],
  ['../src/ui/icons.js', { icon: 'function', hasIcon: 'function', ICON_NAMES: 'object' }],
  [
    '../src/ui/components.js',
    {
      button: 'function',
      iconButton: 'function',
      starButton: 'function',
      toggle: 'function',
      segmented: 'function',
      textField: 'function',
      selectField: 'function',
      autoGrow: 'function',
      chip: 'function',
      progressBar: 'function',
      masteryBar: 'function',
      ring: 'function',
      openModal: 'function',
      confirmDialog: 'function',
      toast: 'function',
      menu: 'function',
      emptyState: 'function',
      callout: 'function',
      kbd: 'function',
      spinner: 'function',
      closeOverlays: 'function',
      hasOpenModal: 'function',
      hasOpenOverlay: 'function',
    },
  ],
  [
    '../src/ui/study-options.js',
    {
      studyOptionsForm: 'function',
      directionText: 'function',
      sideNames: 'function',
      studyOptionsLayout: 'function',
      learnOptions: 'function',
      questionTypeLock: 'function',
      questionTypesHint: 'function',
      roundSizeChoices: 'function',
      ROUND_SIZES: 'object',
      STUDY_OPTION_MODES: 'object', REVIEW_OPTION: 'object', learnReviewEnabled: 'function', setLearnReviewEnabled: 'function' },
  ],
  // Shared core (pre-existing)
  ['../src/core/text.js', { normalizeBasic: 'function', stripDiacritics: 'function', foldUmlauts: 'function', isLetter: 'function', foldScripts: 'function', stripArabicMarks: 'function', hasArabic: 'function', hasHan: 'function', ARABIC_RANGE: 'string', HAN_RANGE: 'string' }],
  // Screens (contract: render(outlet, ctx))
  ['../src/screens/dashboard.js', { render: 'function' }],
  ['../src/screens/editor.js', { render: 'function' }],
  ['../src/screens/set.js', { render: 'function' }],
  ['../src/screens/learn.js', { render: 'function' }],
  ['../src/screens/write.js', { render: 'function' }],
  ['../src/screens/settings.js', { render: 'function' }],
  // Screen helpers (W8 editor, W10 write)
  ['../src/screens/editor-cards.js', { createCardList: 'function' }],
  ['../src/screens/editor-drop.js', { bindPageDrop: 'function' }],
  ['../src/screens/editor-import.js', { createImportPanel: 'function' }],
  [
    '../src/screens/editor-util.js',
    {
      SEPARATORS: 'object',
      SKIP_REASONS: 'object',
      fill: 'function',
      flagTooltip: 'function',
      formatLabel: 'function',
      hasMarker: 'function',
      isApplePlatform: 'function',
      termKey: 'function',
      titleFromFileName: 'function',
    },
  ],
  ['../src/screens/learn-answer.js', { createAnswering: 'function', ADVANCE_MS: 'number', MISS_TITLE: 'string' }],
  ['../src/screens/learn-dialogs.js', { createLearnDialogs: 'function' }],
  ['../src/screens/learn-keys.js', { bindLearnKeys: 'function', choiceDigit: 'function' }],
  ['../src/screens/learn-mc.js', { createMcCard: 'function' }],
  [
    '../src/screens/learn-model.js',
    {
      PRAISE: 'object',
      MAX_SEGMENTS: 'number',
      pickPraise: 'function',
      canResumeLearn: 'function',
      hasLearnAnswers: 'function',
      pendingLearnFeedback: 'function',
      sessionSettings: 'function',
      settingsChanges: 'function',
      restartMessage: 'function',
      choiceTexts: 'function',
      stageStatus: 'function',
      checkpointStatus: 'function',
      masteredLine: 'function',
      checkpointTitle: 'function',
      remainingText: 'function',
      finishTitle: 'function',
      finishSubtitle: 'function',
      restartSessionMessage: 'function',
      scopeText: 'function',
      segmentCount: 'function',
      segmentFills: 'function',
      progressText: 'function', DEMOTED_TEXT: 'string', REVIEW_ALL_LABEL: 'string', REVIEW_ALL_TOOLTIP: 'string', REVIEW_ARIA_LABEL: 'string', REVIEW_LABEL: 'string', REVIEW_TOOLTIP: 'string', allMasteredText: 'function', cardIdsFromHash: 'function', learnCardsPath: 'function', learnSessionDetail: 'function', reviewLine: 'function', runningLearnSession: 'function', sameSubset: 'function' },
  ],
  [
    '../src/screens/learn-views.js',
    {
      allMasteredView: 'function',
      checkpointView: 'function',
      createLearnSidebar: 'function',
      dismissIntroHint: 'function',
      finishView: 'function',
      introHint: 'function',
      introHintDismissed: 'function',
      revealBelowBars: 'function',
      segmentedProgress: 'function', attachReviewMark: 'function', demotedChip: 'function', markDemoted: 'function', reviewChip: 'function' },
  ],
  ['../src/screens/write-card.js', { createCard: 'function' }],
  ['../src/screens/write-clock.js', { createStudyClock: 'function' }],
  ['../src/screens/write-dialogs.js', { ask: 'function', openCardEditor: 'function', openOptionsDialog: 'function' }],
  ['../src/screens/write-keys.js', { bindWriteKeys: 'function', ENTER_SETTLE_MS: 'number', isTypedKey: 'function', routeStudyCommand: 'function', settleEnter: 'function', settleOnLeave: 'function', shortcutAria: 'function', shortcutText: 'function', startsComposition: 'function', studyCommand: 'function' }],
  [
    '../src/screens/write-model.js',
    {
      NAMED_SUBSETS: 'any',
      canResume: 'function',
      canShowResults: 'function',
      charColumns: 'function',
      compactDuration: 'function',
      copyAccepted: 'function',
      gradeQuestion: 'function',
      hasAnswers: 'function',
      hasText: 'function',
      isUsableCard: 'function',
      parseSubset: 'function',
      pendingFeedback: 'function',
      questionInfo: 'function',
      termRows: 'function',
    },
  ],
  [
    '../src/screens/write-views.js',
    {
      createSidebar: 'function',
      emptySubsetView: 'function',
      messageView: 'function',
      missingSetView: 'function',
      resultsView: 'function',
      roundSummaryView: 'function',
      termList: 'function',
      statTile: 'function',
      timeTile: 'function',
      confetti: 'function',
      missesChip: 'function', attachStreakBadge: 'function', keyHints: 'function', studyKeyRows: 'function' },
  ],
  // Store (W2)
  [
    '../src/store/db.js',
    { createDb: 'function', db: 'object', memoryStorage: 'function', DEFAULT_STUDY_OPTIONS: 'object', DEFAULT_SETTINGS: 'object' },
  ],
  ['../src/store/backup.js', { downloadJson: 'function', readJsonFile: 'function', setToText: 'function', downloadText: 'function' }],
  // Core (W2-W5)
  [
    '../src/core/mastery.js',
    {
      MASTERY_STREAK: 'number',
      cardStatus: 'function',
      setProgress: 'function',
      studyStreak: 'function',
      applyAnswer: 'function',
      applyOverride: 'function',
      normalizeProgress: 'function',
    },
  ],
  ['../src/core/langdetect.js', { SUPPORTED: 'object', scoreLanguages: 'function', detectLanguage: 'function', detectColumn: 'function' }],
  ['../src/core/parser.js', { parseVocab: 'function' }],
  [
    '../src/core/grading.js',
    {
      grade: 'function',
      splitAlternatives: 'function',
      diffChars: 'function',
      diffAnswer: 'function',
      ARTICLES: 'object',
      REFLEXIVES: 'object',
      GLUED_ARTICLES: 'object',
      ABBREVIATIONS: 'object',
      DEFAULT_TOLERANCE: 'object',
    },
  ],
  [
    '../src/core/session.js',
    {
      createSession: 'function',
      current: 'function',
      answer: 'function',
      override: 'function',
      isRoundOver: 'function',
      roundSummary: 'function',
      nextRound: 'function',
      isFinished: 'function',
      counters: 'function',
      finalStats: 'function',
      removeCard: 'function',
      tick: 'function',
    },
  ],
  [
    '../src/core/synonyms.js',
    { promptSide: 'function', answerSide: 'function', findSynonymCards: 'function', gradeWithSynonyms: 'function' },
  ],
  [
    '../src/core/learn.js',
    {
      DEFAULT_LEARN: 'object',
      stageFromProgress: 'function',
      createLearn: 'function',
      current: 'function',
      answer: 'function',
      override: 'function',
      isRoundOver: 'function',
      checkpoint: 'function',
      nextRound: 'function',
      isFinished: 'function',
      counts: 'function',
      buildChoices: 'function',
      removeCard: 'function',
      finalStats: 'function',
      tick: 'function',
      matchesProgress: 'function',
      syncProgress: 'function', isReviewQuestion: 'function', reviewStats: 'function', reviewsPerRound: 'function' },
  ],
  // Import adapters (W6)
  ['../src/import/layout.js', { itemsToLines: 'function', estimateSlope: 'function', deskewItems: 'function' }],
  ['../src/import/pdf.js', { extractPdfText: 'function', loadPdfJs: 'function', toLayoutItems: 'function' }],
  [
    '../src/import/ocr.js',
    { recognizeImage: 'function', ocrLangsFor: 'function', createRecognizer: 'function', ocrDataToText: 'function', imageScaleFor: 'function', fixGermanUmlauts: 'function' },
  ],
  ['../src/import/files.js', { readImportFile: 'function', ACCEPT: 'string', detectFileKind: 'function', decodeText: 'function' }],
];

function typeOk(value, kind) {
  if (kind === 'any') return value !== undefined;
  if (kind === 'object') return value !== null && typeof value === 'object';
  return typeof value === kind;
}

for (const [path, exportsSpec] of MODULES) {
  test(`imports ${path.replace('../', '')}`, async () => {
    const mod = await import(path);
    for (const [name, kind] of Object.entries(exportsSpec)) {
      if (!(name in mod)) throw new Error(`${path}: missing export "${name}"`);
      if (!typeOk(mod[name], kind)) throw new Error(`${path}: export "${name}" should be ${kind}, got ${typeof mod[name]}`);
    }
  });
}

// --- Pure smoke checks on W1 modules -------------------------------------

test('icons: every icon named in the spec exists', async () => {
  const { hasIcon } = await import('../src/ui/icons.js');
  const required = [
    'plus', 'search', 'settings', 'star', 'starFilled', 'edit', 'trash', 'copy', 'download', 'upload', 'play', 'check', 'x',
    'arrowLeft', 'arrowRight', 'chevronRight', 'chevronDown', 'volume', 'more', 'rotate', 'sun', 'moon', 'monitor', 'image',
    'fileText', 'sparkles', 'shuffle', 'keyboard', 'flame', 'book', 'swap', 'alert', 'info', 'eye', 'filter', 'grip',
    'clipboard', 'camera', 'layers', 'target', 'trophy', 'clock', 'cards', 'graduationCap', 'flameFilled',
  ];
  const missing = required.filter((n) => !hasIcon(n));
  expect(missing).toEqual([]);
});

test('labels: languages, statuses and plural', async () => {
  const { LANGS, STATUS, NOTE_LABELS, HINT_LABELS, plural, langPair } = await import('../src/lib/labels.js');
  expect(Object.keys(LANGS)).toEqual(['fr', 'en', 'es', 'it', 'ar', 'zh', 'de', 'other']);
  expect(LANGS.fr).toEqual({ name: 'Französisch', short: 'FR', bcp47: 'fr-FR' });
  expect(LANGS.de.bcp47).toBe('de-CH');
  expect(STATUS).toEqual({ new: 'Neu', learning: 'Am Lernen', mastered: 'Gemeistert' });
  expect(NOTE_LABELS.case).toBe('Gross-/Kleinschreibung');
  expect(HINT_LABELS.wrongArticle).toBe('Falscher Artikel');
  expect(plural(1, 'Begriff', 'Begriffe')).toBe('1 Begriff');
  expect(plural(52, 'Begriff', 'Begriffe')).toBe('52 Begriffe');
  expect(plural(0, 'Begriff', 'Begriffe')).toBe('0 Begriffe');
  expect(langPair('fr', 'de')).toBe('FR → DE');
  // Swiss spelling: no sharp s anywhere in the labels
  const all = JSON.stringify([LANGS, STATUS, NOTE_LABELS, HINT_LABELS]);
  expect(all.includes('ß')).toBe(false);
});

test('keyboard: special characters per language', async () => {
  const { SPECIAL_CHARS, charsFor } = await import('../src/lib/keyboard.js');
  expect(SPECIAL_CHARS.fr).toContain('ç');
  expect(SPECIAL_CHARS.fr).toContain('œ');
  expect(SPECIAL_CHARS.de).toEqual(['ä', 'ö', 'ü', 'Ä', 'Ö', 'Ü']);
  expect(SPECIAL_CHARS.en).toEqual([]);
  expect(charsFor('xx')).toEqual([]);
  expect(charsFor('ar')).toEqual([]);
  expect(charsFor('zh')).toEqual(['ü']);
});

test('labels: Arabic and Chinese', async () => {
  const { LANGS, LANG_ORDER, NOTE_LABELS, HINT_LABELS, langName, langShort, langPair } = await import('../src/lib/labels.js');
  expect(LANG_ORDER).toEqual(['fr', 'en', 'es', 'it', 'ar', 'zh', 'de', 'other']);
  expect(Object.keys(LANGS)).toEqual(LANG_ORDER);
  expect(LANGS.ar).toEqual({ name: 'Arabisch', short: 'AR', bcp47: 'ar', rtl: true });
  expect(LANGS.zh).toEqual({ name: 'Chinesisch', short: 'ZH', bcp47: 'zh-CN' });
  // Only Arabic is right to left; the others keep exactly name, short and bcp47.
  for (const code of LANG_ORDER.filter((c) => c !== 'ar')) expect(Object.keys(LANGS[code])).toEqual(['name', 'short', 'bcp47']);
  expect(langName('zh')).toBe('Chinesisch');
  expect(langShort('ar')).toBe('AR');
  expect(langPair('ar', 'de')).toBe('AR → DE');
  expect(NOTE_LABELS.variant).toBe('Schreibvariante');
  expect(NOTE_LABELS.pinyin).toBe('Nur Pinyin');
  expect(NOTE_LABELS.tones).toBe('Töne');
  expect(HINT_LABELS.tonesOnly).toBe('Nur die Töne fehlen');
  // Every note and hint grading can report has a label (unknown keys are dropped silently).
  const notes = ['article', 'pronoun', 'abbreviation', 'partial', 'parentheses', 'pinyin', 'case', 'accents', 'tones', 'variant', 'typo', 'order', 'synonym'];
  for (const n of notes) expect(typeof NOTE_LABELS[n]).toBe('string');
  for (const h of ['wrongArticle', 'missingArticle', 'accentsOnly', 'tonesOnly', 'caseOnly', 'typo', 'almost']) expect(typeof HINT_LABELS[h]).toBe('string');
  expect(JSON.stringify([LANGS, NOTE_LABELS, HINT_LABELS]).includes('ß')).toBe(false);
});

test('labels: textAttrs and fieldAttrs give card text its language and direction', async () => {
  const { textAttrs, fieldAttrs, bcp47 } = await import('../src/lib/labels.js');
  expect(textAttrs('ar')).toEqual({ lang: 'ar', dir: 'rtl' });
  expect(textAttrs('zh')).toEqual({ lang: 'zh-CN', dir: null });
  expect(textAttrs('fr')).toEqual({ lang: 'fr-FR', dir: null });
  expect(textAttrs('de')).toEqual({ lang: 'de-CH', dir: null });
  expect(textAttrs('other')).toEqual({ lang: null, dir: 'auto' });
  expect(textAttrs('xx')).toEqual({ lang: null, dir: 'auto' });
  expect(textAttrs(undefined)).toEqual({ lang: null, dir: 'auto' });
  expect(textAttrs('toString')).toEqual({ lang: null, dir: 'auto' });
  expect(fieldAttrs('ar')).toEqual({ lang: 'ar', dir: 'auto' });
  expect(fieldAttrs('zh')).toEqual({ lang: 'zh-CN', dir: 'auto' });
  expect(fieldAttrs('fr')).toEqual({ lang: 'fr-FR', dir: 'auto' });
  expect(fieldAttrs('other')).toEqual({ lang: null, dir: 'auto' });
  expect(fieldAttrs(null)).toEqual({ lang: null, dir: 'auto' });
  expect(bcp47('it')).toBe('it-IT');
  expect(bcp47('other')).toBe(null);
  expect(bcp47('constructor')).toBe(null);
});

test('router: parsePath matches every route', async () => {
  const { parsePath } = await import('../src/router.js');
  const pick = (r) => ({ name: r.name, params: r.params, query: r.query, full: r.full });
  expect(pick(parsePath(''))).toEqual({ name: 'dashboard', params: {}, query: {}, full: '/' });
  expect(pick(parsePath('#/'))).toEqual({ name: 'dashboard', params: {}, query: {}, full: '/' });
  expect(pick(parsePath('#/new'))).toEqual({ name: 'editor', params: {}, query: {}, full: '/new' });
  expect(pick(parsePath('#/set/abc123'))).toEqual({ name: 'set', params: { id: 'abc123' }, query: {}, full: '/set/abc123' });
  expect(pick(parsePath('/set/abc123/edit'))).toEqual({ name: 'editor', params: { id: 'abc123' }, query: {}, full: '/set/abc123/edit' });
  expect(pick(parsePath('#/set/a_b-C/write?subset=starred'))).toEqual({
    name: 'write',
    params: { id: 'a_b-C' },
    query: { subset: 'starred' },
    full: '/set/a_b-C/write?subset=starred',
  });
  expect(pick(parsePath('#/settings'))).toEqual({ name: 'settings', params: {}, query: {}, full: '/settings' });
  expect(pick(parsePath('#/set/abc123/learn'))).toEqual({ name: 'learn', params: { id: 'abc123' }, query: {}, full: '/set/abc123/learn' });
  expect(pick(parsePath('/set/a_b-C/learn?subset=starred&new=1'))).toEqual({
    name: 'learn',
    params: { id: 'a_b-C' },
    query: { subset: 'starred', new: '1' },
    full: '/set/a_b-C/learn?subset=starred&new=1',
  });
});

test('router: unknown routes fall back to the dashboard; trailing slashes are ignored', async () => {
  const { parsePath, href } = await import('../src/router.js');
  expect(parsePath('#/does/not/exist').name).toBe('dashboard');
  expect(parsePath('#/does/not/exist').full).toBe('/');
  expect(parsePath('#/settings/').name).toBe('settings');
  expect(parsePath('#/set/x/write/').params).toEqual({ id: 'x' });
  expect(parsePath('#/set/x/learn/').name).toBe('learn');
  expect(parsePath('#/set/x/learn/extra').name).toBe('dashboard');
  expect(parsePath('#/set/x/write?subset=missed&a=1').query).toEqual({ subset: 'missed', a: '1' });
  expect(parsePath('#/set/caf%C3%A9').params.id).toBe('café');
  expect(href('/set/x')).toBe('#/set/x');
});

test('index.html links every stylesheet, screen styles included', () => {
  const html = readFile('../index.html');
  const links = [...html.matchAll(/<link rel="stylesheet" href="([^"]+)"/g)].map((m) => m[1]);
  const screens = ['dashboard', 'editor', 'set', 'learn', 'write', 'flashcards', 'exam', 'settings'].map((name) => `styles/screens/${name}.css`);
  for (const href of ['styles/tokens.css', 'styles/base.css', 'styles/components.css', ...screens]) expect(links).toContain(href);
  // Every linked file exists.
  for (const href of links) expect(typeof readFile(`../${href}`)).toBe('string');
});

test('theme: resolveTheme without a DOM', async () => {
  const { resolveTheme } = await import('../src/lib/theme.js');
  expect(resolveTheme('dark')).toBe('dark');
  expect(resolveTheme('light')).toBe('light');
  expect(resolveTheme('system')).toBe('light');
});

test('speech: canSpeak is false without the Web Speech API', async () => {
  const { canSpeak, speak } = await import('../src/lib/speech.js');
  expect(canSpeak()).toBe(false);
  speak('bonjour', 'fr'); // must be a silent no-op
});

await run('imports.test.js');
