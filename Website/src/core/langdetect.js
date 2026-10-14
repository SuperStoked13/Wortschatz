// Language identification for short vocabulary lines (fr / de / en / es / it).
//
// Vocabulary lines are tiny ("calme", "der Mut", "sage"), so classic n-gram
// detectors fail on them. This module combines several weak signals into
// additive evidence scores (roughly log-odds units):
//   - a compact frequent-word lexicon (function words + common school vocabulary)
//   - leading articles / reflexive pronouns (le, die, the, el, gli, sich, s' ...)
//   - diacritics (é ç œ -> fr, ä ö ü -> de, ñ ¿ -> es, ì ò -> it)
//   - German noun capitalisation ("die Frau", mid-line capitals)
//   - typical suffixes (-tion, -euse, -ung, -keit, -ing, -ción, -zione ...)
//   - characteristic character n-grams (sch, eau, th, w, k, z, gli ...)
//   - a character-trigram model trained lazily on the lexicon itself, which
//     generalises to words that are not in the lexicon.
// Column-level detection aggregates soft votes over many lines, so a single
// ambiguous line never decides the language of a whole column.
// Pure and DOM-free (runs under jsc).

import { normalizeBasic } from './text.js';

export const SUPPORTED = ['fr', 'de', 'en', 'es', 'it'];

// Small tie-breaking prior: the app is used by German speakers learning French
// (sometimes English). Only applied when turning scores into probabilities.
const PRIOR = { fr: 0.2, de: 0.25, en: 0.1, es: 0.05, it: 0 };

const SHARP_S = '\u00DF';

// ---------------------------------------------------------------------------
// Lexicon data (lowercase; German sharp s is written as "ss" and folded at
// lookup time so Swiss and German spellings both match).
// ---------------------------------------------------------------------------

const FUNCTION_WORDS = {
  fr: `le la les l' un une des du de d' au aux à a et ou mais donc ni car que qui quoi dont où ce cet cette
    ces c' mon ma mes ton ta tes son sa ses notre nos votre vos leur leurs je j' tu il elle on nous vous ils
    elles me m' te t' se s' moi toi lui eux y en ne n' pas plus jamais rien très trop peu beaucoup bien mal
    aussi encore déjà toujours souvent parfois avec sans pour par dans sur sous chez entre vers depuis
    pendant avant après contre selon quand comme si oui non est sont était être avoir ai as avons avez ont
    fait faire va vont suis es sommes êtes qu' jusqu' lorsqu' puisqu' quelqu' aujourd' quelque chose tout
    toute tous toutes autre même chaque ici là voici voilà demain hier maintenant alors puis ensuite enfin
    qc qch qqch qn qqn quelqu'un`,
  de: `der die das den dem des ein eine einen einem einer eines kein keine keinen keinem und oder aber denn
    sondern doch weil dass wenn als ob ich du er sie es wir ihr mich dich sich mir dir ihm ihn uns euch
    mein meine dein deine sein seine unser unsere euer nicht nichts nie immer oft sehr viel viele wenig
    mehr auch noch schon jetzt heute morgen gestern hier dort da mit ohne für von vom zu zum zur bei beim
    nach aus über unter auf an in im am vor hinter neben zwischen durch gegen um bis seit während wie was
    wer wo wann warum welche welcher welches ist sind war waren bin bist hat haben habe hatte wird werden
    kann können muss müssen will wollen soll sollen darf dürfen etwas jemand jemanden jemandem jemandes
    man alle alles jeder jede jedes ganz etw jdn jdm jds jd sowie also dieser diese dieses`,
  en: `the a an to of and or but so if when because that this these those what who whom which where why how
    i you he she it we they me him her us them my your his its our their is are was were be been being
    have has had do does did will would can could shall should may might must not no yes very too also
    only just more most less some any all each every other another one two with without for from by in on
    at into onto over under about after before between through during against up down out off again then
    now here there today tomorrow yesterday always never often sometimes something somebody someone
    anything nothing everything sth sb smth smb oneself don' doesn' isn' aren' wasn' can' won' didn'
    still yet`,
  es: `el la los las un una unos unas lo y o pero porque que quien quién cual cuál donde dónde cuando cuándo
    como cómo qué por para con sin en de del al a sobre bajo entre hacia hasta desde durante contra según
    yo tú él ella usted nosotros vosotros ellos ellas ustedes me te se nos os le les mi mis tu tus su sus
    nuestro nuestra muy mucho mucha muchos poco también tampoco ya todavía siempre nunca hoy ayer ahora
    aquí allí sí no es son está están era ser estar hay tener tengo tiene hacer ir voy va algo alguien
    nada nadie todo todos otro otra cada este esta estos estas ese esa`,
  it: `il lo la i gli le un uno una un' l' e o ma perché che chi cui dove quando come cosa per con senza in
    di del della dei degli delle al alla ai agli alle dal dalla nel nella sul sulla da a tra fra su sopra
    sotto verso fino durante contro io tu lui lei noi voi loro mi ti si ci vi mio mia miei mie tuo tua suo
    sua nostro nostra molto molta molti poco anche ancora già sempre mai oggi domani ieri adesso ora qui
    qua lì là sì non è sono era essere avere ho hai ha abbiamo hanno fare andare vado va qualcosa
    qualcuno niente nessuno tutto tutti altro altra ogni questo questa quello quella dell' all' dall'
    nell' sull' quell' quest'`,
};

const VOCAB_WORDS = {
  fr: `monsieur messieurs madame mesdames mademoiselle mesdemoiselles homme femme dame enfant garçon fille
    fils père mère frère sœur famille ami amie copain copine nom prénom adresse rue maison numéro ville
    pays école classe professeur élève livre cahier stylo crayon table chaise porte fenêtre chambre
    cuisine salle jardin voiture vélo train avion bateau chien chat oiseau cheval poisson souris vache
    cochon arbre fleur eau pain fromage lait viande pomme fruit légume café thé vin bière repas déjeuner
    dîner jour nuit matin soir semaine mois année an heure minute temps saison printemps été automne
    hiver soleil pluie neige vent mer montagne plage campagne forêt rivière ciel terre monde travail
    métier argent prix magasin marché boulangerie gare billet voyage vacances football musique chanson
    jeu fête anniversaire cadeau vêtement pantalon chemise robe jupe chaussure manteau chapeau tête
    visage figure yeux œil nez bouche oreille cheveux main bras jambe pied corps cœur santé médecin
    hôpital raison courage bêtise beauté charme personne gens peuple histoire langue mot phrase question
    réponse exemple idée problème chose fois partie côté place fin début moment voisin voisine
    venir voir savoir pouvoir vouloir devoir dire parler manger boire dormir lire écrire écouter regarder
    chanter danser jouer travailler habiter aimer adorer détester préférer acheter vendre donner prendre
    mettre trouver chercher appeler ressembler penser croire comprendre apprendre connaître attendre
    entendre répondre ouvrir fermer partir sortir arriver rester tomber courir marcher nager voyager
    laver commencer finir choisir réussir nommer épouser divorcer
    grand grande petit petite beau bel belle joli jolie laid laide moche bon bonne mauvais mauvaise
    gentil gentille méchant méchante content contente heureux heureuse triste fatigué fatiguée malade
    jeune vieux vieille nouveau nouvelle blanc blanche noir noire rouge vert verte bleu bleue jaune gris
    grise marron facile difficile cher chère gros grosse long longue court courte chaud chaude froid
    froide sage brave aimable calme tranquille sérieux sérieuse sympathique charmant charmante
    raisonnable courageux courageuse bête lâche comique drôle marié mariée veuf veuve séparé séparée
    seul seule premier première dernier dernière intéressant ennuyeux génial vrai faux fausse
    attirant attirante poli polie timide paresseux paresseuse travailleur intelligent intelligente
    deux trois quatre cinq six sept huit neuf dix onze douze treize quatorze quinze seize vingt trente
    quarante cinquante soixante cent mille lundi mardi mercredi jeudi vendredi samedi dimanche janvier
    février mars avril mai juin juillet août septembre octobre novembre décembre`,
  de: `herr herren mann männer frau frauen dame fräulein kind kinder junge mädchen name namen familienname
    nachname vorname person leute adresse anschrift strasse hausnummer haus wohnung zimmer küche garten
    schule klasse lehrer lehrerin schüler schülerin buch heft stift tisch stuhl tür fenster auto fahrrad
    zug flugzeug schiff hund katze vogel pferd fisch maus kuh schwein baum blume wasser brot käse milch
    fleisch apfel obst gemüse kaffee tee wein bier frühstück mittagessen abendessen tag nacht abend
    woche monat jahr stunde minute zeit wetter sonne regen schnee wind meer berg strand land wald fluss
    himmel erde welt arbeit beruf geld preis geschäft laden markt bäckerei bahnhof fahrkarte reise
    ferien urlaub musik lied spiel fest geburtstag geschenk kleidung hose hemd kleid rock schuh mantel
    hut kopf gesicht auge augen nase mund ohr haar haare hand arm bein fuss körper herz gesundheit arzt
    krankenhaus vernunft mut dummheit schönheit charme volk geschichte sprache wort satz frage antwort
    beispiel idee problem sache teil seite platz ende anfang freund freundin vater mutter bruder
    schwester eltern sohn tochter familie nachbar nachbarin
    sein haben werden machen gehen kommen sehen wissen sagen sprechen reden essen trinken schlafen lesen
    schreiben hören schauen singen tanzen spielen arbeiten wohnen lieben mögen hassen kaufen verkaufen
    geben nehmen legen stellen finden suchen nennen heissen ähneln gleichen denken glauben verstehen
    lernen kennen warten antworten öffnen schliessen fahren laufen bleiben fallen rennen schwimmen
    reisen waschen beginnen anfangen aufhören wählen helfen brauchen bekommen zeigen erklären erzählen
    fragen heiraten erscheinen
    gross grosse klein kleine schön hübsch hässlich gut schlecht lieb nett freundlich böse gemein
    glücklich traurig müde krank jung alt neu weiss schwarz rot grün blau gelb grau braun leicht schwer
    einfach teuer billig dick dünn lang kurz warm kalt heiss brav artig ruhig still komisch lustig ernst
    ernsthaft sympathisch vernünftig mutig feige dumm klug verheiratet verwitwet getrennt geschieden
    ledig allein erste letzte wichtig interessant langweilig toll wahr falsch richtig attraktiv
    anziehend gütig ähnlich gleich charmant höflich schüchtern faul fleissig
    eins zwei drei vier fünf sechs sieben acht neun zehn elf zwölf dreizehn vierzehn fünfzehn sechzehn
    siebzehn achtzehn neunzehn zwanzig dreissig vierzig fünfzig hundert tausend montag dienstag mittwoch
    donnerstag freitag samstag sonntag januar februar märz april mai juni juli august september oktober
    november dezember`,
  en: `house home room kitchen garden school class teacher student pupil book pen table chair door window
    car bike train plane ship dog cat bird horse fish mouse cow pig tree flower water bread cheese milk
    meat apple fruit vegetable coffee tea wine beer breakfast lunch dinner day night morning evening week
    month year hour minute time weather sun rain snow wind sea mountain beach country forest river sky
    earth world work job money price shop market station ticket journey holiday sport music song film
    game party birthday present clothes trousers shirt dress skirt shoe coat hat head face eye eyes nose
    mouth ear hair hand arm leg foot body heart health doctor hospital people story language word
    sentence question answer example idea problem thing part side place end beginning friend father
    mother brother sister parents son daughter man woman child children boy girl name surname address
    street number family person neighbour neighbor
    appear be have do make go come see know say speak talk eat drink sleep read write listen hear look
    watch sing dance play live love like hate buy sell give take put find search call think believe
    understand learn wait answer open close leave stay fall run walk swim travel wash begin start finish
    choose help need get show explain tell ask become seem keep bring meet feel marry
    big small little beautiful pretty ugly good bad nice kind friendly angry happy sad tired ill sick
    young old new white black red green blue yellow grey gray brown easy difficult hard expensive cheap
    fat thin long short warm cold hot quiet calm funny serious brave clever stupid married single
    important interesting boring great true false right wrong first last polite shy lazy
    quickly slowly really happiness kindness building clothing
    lesson chapter exercise unit homework grammar vocabulary newspaper advertisement channel
    three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen
    eighteen nineteen twenty thirty forty fifty hundred thousand monday tuesday wednesday thursday friday
    saturday sunday january february march april may june july august september october november
    december`,
  es: `casa perro gato niño niña hombre mujer señor señora chico chica amigo amiga padre madre hermano
    hermana familia nombre apellido calle ciudad pueblo país escuela clase profesor alumno libro
    cuaderno mesa silla puerta ventana coche bicicleta tren avión barco pájaro caballo pez árbol flor
    agua pan queso leche carne manzana fruta verdura café té vino cerveza desayuno comida cena día
    noche mañana tarde semana mes año hora minuto tiempo sol lluvia nieve viento mar montaña playa campo
    bosque río cielo tierra mundo trabajo dinero precio tienda mercado estación billete viaje vacaciones
    deporte música canción película juego fiesta cumpleaños regalo ropa pantalones camisa vestido falda
    zapato abrigo sombrero cabeza cara ojo ojos nariz boca oreja pelo mano brazo pierna pie cuerpo
    corazón salud médico hospital gente historia idioma lengua palabra frase pregunta respuesta ejemplo
    idea problema cosa vez parte lado lugar fin principio momento universidad verdad libertad
    información
    hablar comer beber vivir dormir leer escribir escuchar mirar cantar bailar jugar trabajar amar
    querer odiar comprar vender dar tomar poner encontrar buscar llamar llamarse pensar creer entender
    aprender conocer esperar contestar abrir cerrar salir llegar quedarse caer correr andar caminar
    nadar viajar lavar empezar terminar elegir ayudar necesitar decir saber poder ver venir
    grande pequeño pequeña bonito bonita guapo guapa feo fea bueno buena malo mala simpático simpática
    antipático amable contento contenta feliz triste cansado cansada enfermo enferma joven viejo vieja
    nuevo nueva blanco blanca negro negra rojo roja verde azul amarillo gris marrón fácil difícil caro
    barato gordo delgado largo corto caliente frío fría tranquilo divertido serio valiente listo tonto
    casado soltero importante interesante aburrido
    dos tres cuatro cinco seis siete ocho nueve diez once doce trece catorce quince dieciséis veinte
    treinta cuarenta cincuenta cien mil lunes martes miércoles jueves viernes sábado domingo enero
    febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre`,
  it: `casa cane gatto bambino bambina ragazzo ragazza uomo donna signore signora amico amica padre madre
    fratello sorella famiglia nome cognome indirizzo via strada città paese scuola classe professore
    studente studentessa libro quaderno penna tavolo sedia porta finestra macchina bicicletta treno aereo
    nave uccello cavallo pesce albero fiore acqua pane formaggio latte carne mela frutta verdura caffè
    vino birra colazione pranzo cena giorno notte mattina sera settimana mese anno ora minuto tempo sole
    pioggia neve vento mare montagna spiaggia campagna bosco fiume cielo terra mondo lavoro soldi prezzo
    negozio mercato stazione biglietto viaggio vacanze musica canzone gioco festa compleanno regalo
    vestiti pantaloni camicia vestito gonna scarpa cappotto cappello testa faccia viso occhio occhi naso
    bocca orecchio capelli mano braccio gamba piede corpo cuore salute medico ospedale gente storia
    lingua parola frase domanda risposta esempio idea problema volta parte lato posto fine inizio
    momento università libertà
    parlare mangiare bere vivere dormire leggere scrivere ascoltare guardare cantare ballare giocare
    lavorare abitare amare volere odiare comprare vendere dare prendere mettere trovare cercare chiamare
    chiamarsi pensare credere capire imparare conoscere aspettare rispondere aprire chiudere partire
    uscire arrivare restare cadere correre camminare nuotare viaggiare lavare cominciare finire
    scegliere aiutare dire sapere potere dovere vedere venire
    grande piccolo piccola bello bella brutto brutta buono buona cattivo cattiva simpatico simpatica
    gentile contento contenta felice triste stanco stanca malato malata giovane vecchio vecchia nuovo
    nuova bianco bianca nero nera rosso rossa verde azzurro blu giallo grigio marrone facile difficile
    caro cara economico grasso magro lungo lunga corto corta caldo calda freddo fredda tranquillo
    divertente serio coraggioso stupido sposato sposata importante interessante noioso
    due tre quattro cinque sei sette otto nove dieci undici dodici tredici quattordici quindici sedici
    venti trenta quaranta cinquanta cento mille lunedì martedì mercoledì giovedì venerdì sabato domenica
    gennaio febbraio marzo aprile maggio giugno luglio agosto settembre ottobre novembre dicembre`,
};

// French words with German-looking "ei" / "ein" letter groups ("plein",
// "peindre"). They are known directly but kept out of the trigram model, which
// would otherwise make German "-ein" / "-einte" words ("vereint", "meinte")
// look French.
// Also greetings, thanks, yes/no and other first-lesson words. Alone on a side
// ("Bonjour Hallo", "Merci Danke") nothing else gives their language away, and
// the trigrams guess wrong ("Hallo" and "Merci" look Italian). Kept out of the
// trigram model so that the scores of all other words stay unchanged.
const LEXICON_ONLY = {
  fr: `plein pleine pleins pleines peine reine serein sereine sereins sereines frein freiner freinage
    peindre peint peinte peintre peinture atteindre atteinte éteindre éteinte craindre crainte ceinture
    teindre teinte feindre enceinte baleine haleine veine enseigner enseignant
    bonjour bonsoir salut coucou merci adieu revoir bientôt bienvenue bisous enchanté enchantée excusez
    désolé désolée félicitations volontiers accord`,
  de: `hallo tschüss tschüs danke bitte ja nein guten wiedersehen willkommen entschuldigung verzeihung servus
    moin grüezi grüss salü tschau`,
  en: `hello hi bye goodbye thanks thank please sorry welcome cheers`,
  es: `hola adiós gracias perdón bienvenido bienvenida buenos buenas días noches tardes`,
  it: `ciao grazie prego buongiorno buonasera buonanotte arrivederci benvenuto benvenuta scusa scusi`,
};

const W_FUNCTION = 1.4;
const W_VOCAB = 2.0;
const W_LEXICON_ONLY = 4.0; // makes up for the missing trigram evidence
const W_UNIQUE_BONUS = 0.8;

// Article / pronoun at the start of a line or of a comma-separated segment.
const LEADING = {
  le: { fr: 2.2, it: 0.5 },
  la: { fr: 1.4, es: 1.1, it: 1.1 },
  les: { fr: 2.8 },
  "l'": { fr: 2.2, it: 1.2 },
  un: { fr: 1.3, es: 1.0, it: 1.0 },
  une: { fr: 2.8 },
  des: { fr: 2.2, de: 0.3 },
  du: { fr: 2.6 },
  se: { fr: 2.0, es: 0.9, it: 0.7 },
  "s'": { fr: 2.4, it: 0.5 },
  der: { de: 3 },
  die: { de: 2.6, en: 0.2 },
  das: { de: 3 },
  den: { de: 2.4 },
  dem: { de: 3 },
  ein: { de: 2.8 },
  eine: { de: 3 },
  einen: { de: 3 },
  einem: { de: 3 },
  einer: { de: 3 },
  eines: { de: 3 },
  sich: { de: 3.2 },
  the: { en: 3.2 },
  a: { en: 1.5, es: 0.3, it: 0.3 },
  an: { en: 2.0, de: 0.6 },
  to: { en: 2.6 },
  el: { es: 3 },
  los: { es: 2.8 },
  las: { es: 2.8 },
  una: { es: 1.4, it: 1.4 },
  unos: { es: 3 },
  unas: { es: 3 },
  lo: { es: 1.0, it: 1.4 },
  il: { it: 2.8, fr: 0.6 },
  gli: { it: 3.2 },
  i: { it: 1.6, en: 0.4 },
  uno: { it: 2.2, es: 0.8 },
  "un'": { it: 3 },
};

// German determiners after which a capitalised word is almost surely a noun.
const DE_DETERMINERS = new Set(
  `der die das den dem des ein eine einen einem einer eines kein keine keinen keinem keiner mein meine
   dein deine sein seine ihr ihre unser unsere euer eure dieser diese dieses jeder jede jedes zum zur im
   am vom beim`.split(/\s+/),
);

const CHAR_WEIGHTS = {
  'é': { fr: 1.6, es: 0.5, it: 0.4 },
  'è': { fr: 1.6, it: 0.9 },
  'ê': { fr: 2.4 },
  'â': { fr: 2.4 },
  'î': { fr: 2.4 },
  'ô': { fr: 2.4 },
  'û': { fr: 2.4 },
  'ë': { fr: 1.8 },
  'ï': { fr: 2.0 },
  'ç': { fr: 2.6 },
  'œ': { fr: 3 },
  'à': { fr: 1.2, it: 1.0 },
  'ù': { fr: 1.4, it: 0.9 },
  'ä': { de: 2.6 },
  'ö': { de: 2.6 },
  'ü': { de: 2.6, es: 0.3 },
  [SHARP_S]: { de: 3.2 },
  'ñ': { es: 3.4 },
  'á': { es: 2.2 },
  'í': { es: 2.0, it: 0.4 },
  'ó': { es: 2.0, it: 0.4 },
  'ú': { es: 2.0, it: 0.2 },
  'ì': { it: 2.6 },
  'ò': { it: 2.6 },
  '¿': { es: 3.4 },
  '¡': { es: 3.4 },
};

// Word endings; per word only the strongest matching suffix of each language counts.
const SUFFIXES = {
  fr: [
    ['euses', 2.6], ['euse', 2.6], ['eux', 2.2], ['eaux', 2.4], ['eau', 2.4], ['tion', 0.8], ['ment', 0.9],
    ['ée', 1.0], ['ées', 1.2], ['ier', 0.9], ['oyer', 2.0], ['ayer', 1.0], ['uyer', 2.0], ['ière', 2.0], ['oir', 2.0], ['oire', 2.0], ['ette', 2.0],
    ['elle', 1.0], ['ique', 2.0], ['isme', 1.2], ['ance', 0.9], ['ence', 0.7], ['esse', 1.4], ['eur', 1.8],
    ['eure', 2.0], ['aire', 1.4], ['oise', 2.0], ['ois', 1.2], ['ille', 1.8], ['eille', 2.4], ['ail', 1.4],
    ['aille', 2.2], ['ouille', 2.6], ['ais', 1.2], ['ait', 1.4], ['ez', 1.2], ['ons', 0.8], ['ant', 0.8],
    ['ante', 0.9], ['ent', 0.5], ['er', 1.0], ['ir', 0.5], ['re', 0.5], ['age', 0.9], ['té', 1.2],
    ['eil', 2.0], ['otte', 2.0], ['ain', 1.4], ['aine', 1.6], ['ienne', 2.4], ['oux', 2.4], ['ude', 0.8],
    ['eindre', 3.0], ['aindre', 3.0], ['oindre', 3.0], ['einture', 2.6],
  ],
  de: [
    ['ung', 3], ['ungen', 3], ['heit', 3], ['keit', 3], ['lich', 2.6], ['isch', 2.6], ['chen', 2.2],
    ['schaft', 3], ['ieren', 2.6], ['iert', 2.4], ['ig', 1.4], ['nis', 2.0], ['tum', 2.0], ['haft', 2.6],
    ['sam', 1.0], ['bar', 1.0], ['los', 0.9], ['lein', 2.6], ['eln', 2.0], ['ern', 1.5], ['en', 1.0],
    ['er', 0.5], ['tz', 2.4], ['ck', 1.6], ['cht', 2.2], ['ft', 1.0], ['st', 0.6], ['ss', 0.8], ['ei', 1.2],
    ['tet', 1.4], ['det', 1.2], ['rn', 1.2], ['hn', 1.4], ['hl', 1.4],
  ],
  en: [
    ['ing', 2.6], ['ly', 2.0], ['ness', 3], ['ful', 2.6], ['less', 2.2], ['ous', 2.0], ['ity', 1.6],
    ['ship', 2.4], ['ish', 1.6], ['ed', 1.2], ['tion', 0.8], ['able', 0.8], ['ible', 0.6], ['ward', 2.0],
    ['y', 0.7], ['ght', 2.4], ['ay', 1.0], ['ey', 1.0], ['ow', 1.0], ['th', 1.6],
  ],
  es: [
    ['ción', 3.4], ['ciones', 3.4], ['dad', 3], ['ado', 1.6], ['ada', 1.2], ['ido', 1.6], ['ida', 1.2],
    ['mente', 1.4], ['os', 1.0], ['as', 0.6], ['ar', 1.4], ['er', 0.5], ['ir', 0.6], ['ería', 2.6],
    ['illa', 2.0], ['illo', 2.0], ['aza', 1.0], ['azo', 1.2], ['udo', 1.0], ['ez', 0.8], ['oso', 1.2], ['osa', 1.2],
    ['ito', 1.0], ['ita', 0.8], ['dor', 1.4], ['ón', 1.6], ['ía', 1.6], ['eza', 1.6], ['ero', 0.9],
    ['iento', 2.2], ['o', 0.5],
  ],
  it: [
    ['zione', 3.4], ['zioni', 3.4], ['ità', 3], ['tà', 2.6], ['ino', 1.0], ['etto', 2.0], ['etta', 1.6],
    ['ezza', 3], ['are', 1.0], ['ere', 1.0], ['ire', 0.6], ['mente', 1.4], ['oni', 1.4], ['ati', 1.4],
    ['iti', 1.4], ['ato', 1.2], ['uto', 1.6], ['ello', 1.4], ['i', 0.7], ['o', 0.5], ['cci', 2.4],
    ['zzo', 2.4], ['zza', 2.4], ['gno', 1.6], ['glio', 2.6], ['ggio', 2.6],
  ],
};

const CONSONANT_END = { fr: 0.3, de: 0.3, en: 0.3, es: 0.3 };

// Characteristic letter groups, counted once per word.
const NGRAMS = [
  ['sch', { de: 1.8 }],
  ['tsch', { de: 1.0 }],
  ['eau', { fr: 2.2 }],
  ['ou', { fr: 0.9, en: 0.4 }],
  ['qu', { fr: 0.7, es: 0.5, it: 0.5, en: 0.2 }],
  ['th', { en: 1.4, de: 0.2 }],
  ['w', { de: 0.9, en: 0.9 }],
  ['k', { de: 1.0, en: 0.4 }],
  ['z', { de: 0.8, it: 0.8, es: 0.3 }],
  ['ch', { de: 0.5, fr: 0.5 }],
  ['ei', { de: 1.0 }],
  ['ie', { de: 0.5, fr: 0.2 }],
  ['eu', { fr: 0.6, de: 0.6 }],
  ['oi', { fr: 1.0 }],
  ['ai', { fr: 0.6 }],
  ['gn', { fr: 0.5, it: 0.7 }],
  ['gli', { it: 1.6 }],
  ['zz', { it: 1.8 }],
  ['cc', { it: 1.0 }],
  ['ck', { de: 1.0, en: 0.6 }],
  ['tz', { de: 1.4 }],
  ['pf', { de: 1.4 }],
  ['wh', { en: 1.8 }],
  ['sh', { en: 1.4 }],
  ['ght', { en: 2.0 }],
  ['ee', { en: 0.8, de: 0.4 }],
  ['oo', { en: 1.2 }],
  ['ea', { en: 0.6 }],
  ['y', { en: 0.7, es: 0.2 }],
  ['ae', { de: 0.4 }],
  ['ue', { de: 0.3, es: 0.4 }],
  ['uo', { it: 1.0 }],
  ['rr', { es: 0.5, it: 0.3 }],
];

// ---------------------------------------------------------------------------
// Lazily built tables
// ---------------------------------------------------------------------------

let tables = null;

function words(str) {
  return str.split(/\s+/).filter(Boolean);
}

function buildTables() {
  const lexicon = new Map(); // word -> { lang: weight }
  const add = (word, lang, w) => {
    let entry = lexicon.get(word);
    if (!entry) lexicon.set(word, (entry = {}));
    entry[lang] = Math.max(entry[lang] || 0, w);
  };
  for (const lang of SUPPORTED) {
    for (const w of words(FUNCTION_WORDS[lang])) add(w, lang, W_FUNCTION);
    for (const w of words(VOCAB_WORDS[lang])) add(w, lang, W_VOCAB);
    for (const w of words(LEXICON_ONLY[lang] || '')) add(w, lang, W_LEXICON_ONLY);
  }
  // Words known in a single language are stronger evidence than shared ones.
  for (const entry of lexicon.values()) {
    const langs = Object.keys(entry);
    if (langs.length === 1) entry[langs[0]] += W_UNIQUE_BONUS;
  }

  // Character-trigram model per language, trained on the lexicon words.
  const counts = {};
  const totals = {};
  const vocab = new Set();
  for (const lang of SUPPORTED) {
    const c = new Map();
    let total = 0;
    const all = words(FUNCTION_WORDS[lang]).concat(words(VOCAB_WORDS[lang]));
    for (const raw of all) {
      const w = raw.replace(/'/g, '');
      if (w.length < 2) continue;
      for (const g of trigrams(w)) {
        c.set(g, (c.get(g) || 0) + 1);
        vocab.add(g);
        total++;
      }
    }
    counts[lang] = c;
    totals[lang] = total;
  }
  const V = vocab.size + 2000;
  return { lexicon, counts, totals, V };
}

function getTables() {
  if (!tables) tables = buildTables();
  return tables;
}

function trigrams(word) {
  const s = ` ${word} `;
  const out = [];
  for (let i = 0; i + 3 <= s.length; i++) out.push(s.slice(i, i + 3));
  return out;
}

// ---------------------------------------------------------------------------
// Scoring
// ---------------------------------------------------------------------------

const TOKEN_RE = /\p{L}+'?/gu;
const SEGMENT_BREAK = /[,;/(|:]|\s-\s|^\s*-\s/;
const TRIGRAM_K = 0.3;
const TRIGRAM_WEIGHT = 0.3;
const TRIGRAM_CAP = 3;

function emptyScores() {
  return { fr: 0, de: 0, en: 0, es: 0, it: 0 };
}

function addWeights(out, weights, factor = 1) {
  for (const lang in weights) out[lang] += weights[lang] * factor;
}

function foldKey(token) {
  return token.split(SHARP_S).join('ss');
}

// "Frau" yes; "frau", "FRAU", "l'" no.
function isCapitalised(token) {
  const first = token[0];
  if (first === first.toLowerCase()) return false;
  const rest = token.slice(1).replace(/'/g, '');
  return rest.length > 0 && rest !== rest.toUpperCase();
}

function trigramEvidence(word, t, out) {
  const ll = {};
  let min = Infinity;
  const grams = trigrams(word);
  for (const lang of SUPPORTED) {
    const c = t.counts[lang];
    const denom = Math.log(t.totals[lang] + TRIGRAM_K * t.V);
    let sum = 0;
    for (const g of grams) sum += Math.log((c.get(g) || 0) + TRIGRAM_K) - denom;
    ll[lang] = sum;
    if (sum < min) min = sum;
  }
  for (const lang of SUPPORTED) out[lang] += Math.min(TRIGRAM_CAP, (ll[lang] - min) * TRIGRAM_WEIGHT);
}

// Additive, non-negative evidence per language (higher = more likely).
export function scoreLanguages(text) {
  const out = emptyScores();
  try {
    const s = normalizeBasic(text == null ? '' : String(text)).slice(0, 4000);
    if (!s || !/\p{L}/u.test(s)) return out;
    const t = getTables();

    // Diacritics: first occurrence of each character counts fully, repeats half.
    const seen = new Map();
    for (const ch of s.toLowerCase()) {
      const w = CHAR_WEIGHTS[ch];
      if (!w) continue;
      const n = seen.get(ch) || 0;
      seen.set(ch, n + 1);
      addWeights(out, w, n === 0 ? 1 : n < 4 ? 0.5 : 0);
    }

    TOKEN_RE.lastIndex = 0;
    let m;
    let prevEnd = 0;
    let prevLower = null;
    let index = 0;
    while ((m = TOKEN_RE.exec(s)) !== null) {
      const token = m[0];
      const lower = token.toLowerCase();
      const key = foldKey(lower);
      const gap = s.slice(prevEnd, m.index);
      const leading = index === 0 || SEGMENT_BREAK.test(gap);

      // Lexicon
      const lex = t.lexicon.get(key);
      if (lex) addWeights(out, lex);

      // Leading article / reflexive pronoun
      if (leading && LEADING[key]) addWeights(out, LEADING[key], index === 0 ? 1 : 0.7);

      // German noun capitalisation
      if (isCapitalised(token)) {
        if (prevLower && DE_DETERMINERS.has(prevLower) && !SEGMENT_BREAK.test(gap)) out.de += 2.4;
        else if (!leading) out.de += 1.0;
        else if (!LEADING[key]) out.de += 0.5;
      }

      const bare = key.replace(/'/g, '');
      if (bare.length >= 2) {
        // Suffixes
        if (bare.length >= 4) {
          for (const lang of SUPPORTED) {
            let best = 0;
            for (const [suffix, w] of SUFFIXES[lang]) {
              if (w > best && bare.length >= suffix.length + 2 && bare.endsWith(suffix)) best = w;
            }
            out[lang] += best;
          }
        }
        // Letter groups
        for (const [gram, w] of NGRAMS) if (bare.includes(gram)) addWeights(out, w);
        // Italian words almost always end in a vowel.
        if (bare.length >= 4 && !/[aeiouàèéìòùy]$/.test(bare)) addWeights(out, CONSONANT_END);
        // Trigram model
        trigramEvidence(bare, t, out);
      }

      prevEnd = m.index + token.length;
      prevLower = lower;
      index++;
    }
    for (const lang of SUPPORTED) out[lang] = Math.round(out[lang] * 1000) / 1000;
  } catch {
    return emptyScores();
  }
  return out;
}

// Scores (plus the tie-breaking prior) -> probability distribution.
function softmax(scores) {
  let max = -Infinity;
  for (const lang of SUPPORTED) max = Math.max(max, scores[lang] + PRIOR[lang]);
  const p = {};
  let sum = 0;
  for (const lang of SUPPORTED) {
    p[lang] = Math.exp(scores[lang] + PRIOR[lang] - max);
    sum += p[lang];
  }
  for (const lang of SUPPORTED) p[lang] /= sum;
  return p;
}

function hasEvidence(scores) {
  for (const lang of SUPPORTED) if (scores[lang] >= 0.3) return true;
  return false;
}

function rank(map) {
  return SUPPORTED.slice().sort((a, b) => map[b] - map[a] || PRIOR[b] - PRIOR[a]);
}

// Most likely language of a single text with a 0..1 confidence.
export function detectLanguage(text) {
  try {
    const scores = scoreLanguages(text);
    if (!hasEvidence(scores)) return { lang: 'unknown', confidence: 0 };
    const p = softmax(scores);
    const [top] = rank(p);
    return { lang: top, confidence: Math.round(p[top] * 1000) / 1000 };
  } catch {
    return { lang: 'unknown', confidence: 0 };
  }
}

// Language of a whole column (many short lines). Every line casts a soft vote
// (its probability distribution); summed evidence breaks near-ties.
export function detectColumn(lines) {
  try {
    const list = Array.isArray(lines) ? lines : lines == null ? [] : [lines];
    const votes = emptyScores();
    const evidence = emptyScores();
    let n = 0;
    for (const line of list) {
      const scores = scoreLanguages(line);
      if (!hasEvidence(scores)) continue;
      const p = softmax(scores);
      let max = 0;
      for (const lang of SUPPORTED) max = Math.max(max, scores[lang]);
      for (const lang of SUPPORTED) {
        votes[lang] += p[lang];
        // Cap the influence of a single long line on the evidence sum.
        evidence[lang] += Math.max(-8, scores[lang] - max);
      }
      n++;
    }
    if (n === 0) return { lang: 'unknown', confidence: 0 };
    let order = rank(votes);
    const [a, b] = order;
    if (Math.abs(votes[a] - votes[b]) / n < 0.04 && evidence[b] > evidence[a]) order = [b, a];
    const top = order[0];
    const second = order[1];
    const share = votes[top] / n;
    const secondShare = votes[second] / n;
    const separation = share / (share + secondShare);
    const sizeFactor = Math.min(1, 0.7 + 0.1 * n);
    const confidence = Math.max(0, Math.min(1, separation * sizeFactor));
    return { lang: top, confidence: Math.round(confidence * 1000) / 1000 };
  } catch {
    return { lang: 'unknown', confidence: 0 };
  }
}
