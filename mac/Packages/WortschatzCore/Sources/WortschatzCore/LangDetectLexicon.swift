// Lexicon data of src/core/langdetect.js (FUNCTION_WORDS, VOCAB_WORDS, LEXICON_ONLY), copied word
// for word. Lowercase; the German sharp s is written as "ss" and folded at lookup time so Swiss and
// German spellings both match. Words are separated by whitespace; the line breaks carry no meaning.
// Keep this file in sync with the web reference (the langdetect parity fixture checks the result).

extension LangDetect {
    /// `FUNCTION_WORDS`: articles, pronouns, prepositions, auxiliaries and other frequent words.
    static let functionWords: [Lang: String] = [
        .fr: """
            le la les l' un une des du de d' au aux à a et ou mais donc ni car que qui quoi dont où ce cet cette ces
            c' mon ma mes ton ta tes son sa ses notre nos votre vos leur leurs je j' tu il elle on nous vous ils
            elles me m' te t' se s' moi toi lui eux y en ne n' pas plus jamais rien très trop peu beaucoup bien mal
            aussi encore déjà toujours souvent parfois avec sans pour par dans sur sous chez entre vers depuis
            pendant avant après contre selon quand comme si oui non est sont était être avoir ai as avons avez ont
            fait faire va vont suis es sommes êtes qu' jusqu' lorsqu' puisqu' quelqu' aujourd' quelque chose tout
            toute tous toutes autre même chaque ici là voici voilà demain hier maintenant alors puis ensuite enfin
            qc qch qqch qn qqn quelqu'un
            """,
        .de: """
            der die das den dem des ein eine einen einem einer eines kein keine keinen keinem und oder aber denn
            sondern doch weil dass wenn als ob ich du er sie es wir ihr mich dich sich mir dir ihm ihn uns euch mein
            meine dein deine sein seine unser unsere euer nicht nichts nie immer oft sehr viel viele wenig mehr auch
            noch schon jetzt heute morgen gestern hier dort da mit ohne für von vom zu zum zur bei beim nach aus
            über unter auf an in im am vor hinter neben zwischen durch gegen um bis seit während wie was wer wo wann
            warum welche welcher welches ist sind war waren bin bist hat haben habe hatte wird werden kann können
            muss müssen will wollen soll sollen darf dürfen etwas jemand jemanden jemandem jemandes man alle alles
            jeder jede jedes ganz etw jdn jdm jds jd sowie also dieser diese dieses
            """,
        .en: """
            the a an to of and or but so if when because that this these those what who whom which where why how i
            you he she it we they me him her us them my your his its our their is are was were be been being have
            has had do does did will would can could shall should may might must not no yes very too also only just
            more most less some any all each every other another one two with without for from by in on at into onto
            over under about after before between through during against up down out off again then now here there
            today tomorrow yesterday always never often sometimes something somebody someone anything nothing
            everything sth sb smth smb oneself don' doesn' isn' aren' wasn' can' won' didn' still yet
            """,
        .es: """
            el la los las un una unos unas lo y o pero porque que quien quién cual cuál donde dónde cuando cuándo
            como cómo qué por para con sin en de del al a sobre bajo entre hacia hasta desde durante contra según yo
            tú él ella usted nosotros vosotros ellos ellas ustedes me te se nos os le les mi mis tu tus su sus
            nuestro nuestra muy mucho mucha muchos poco también tampoco ya todavía siempre nunca hoy ayer ahora aquí
            allí sí no es son está están era ser estar hay tener tengo tiene hacer ir voy va algo alguien nada nadie
            todo todos otro otra cada este esta estos estas ese esa
            """,
        .it: """
            il lo la i gli le un uno una un' l' e o ma perché che chi cui dove quando come cosa per con senza in di
            del della dei degli delle al alla ai agli alle dal dalla nel nella sul sulla da a tra fra su sopra sotto
            verso fino durante contro io tu lui lei noi voi loro mi ti si ci vi mio mia miei mie tuo tua suo sua
            nostro nostra molto molta molti poco anche ancora già sempre mai oggi domani ieri adesso ora qui qua lì
            là sì non è sono era essere avere ho hai ha abbiamo hanno fare andare vado va qualcosa qualcuno niente
            nessuno tutto tutti altro altra ogni questo questa quello quella dell' all' dall' nell' sull' quell'
            quest'
            """,
    ]

    /// `VOCAB_WORDS`: common school vocabulary (nouns, verbs, adjectives, numbers, days, months).
    static let vocabWords: [Lang: String] = [
        .fr: """
            monsieur messieurs madame mesdames mademoiselle mesdemoiselles homme femme dame enfant garçon fille fils
            père mère frère sœur famille ami amie copain copine nom prénom adresse rue maison numéro ville pays
            école classe professeur élève livre cahier stylo crayon table chaise porte fenêtre chambre cuisine salle
            jardin voiture vélo train avion bateau chien chat oiseau cheval poisson souris vache cochon arbre fleur
            eau pain fromage lait viande pomme fruit légume café thé vin bière repas déjeuner dîner jour nuit matin
            soir semaine mois année an heure minute temps saison printemps été automne hiver soleil pluie neige vent
            mer montagne plage campagne forêt rivière ciel terre monde travail métier argent prix magasin marché
            boulangerie gare billet voyage vacances football musique chanson jeu fête anniversaire cadeau vêtement
            pantalon chemise robe jupe chaussure manteau chapeau tête visage figure yeux œil nez bouche oreille
            cheveux main bras jambe pied corps cœur santé médecin hôpital raison courage bêtise beauté charme
            personne gens peuple histoire langue mot phrase question réponse exemple idée problème chose fois partie
            côté place fin début moment voisin voisine venir voir savoir pouvoir vouloir devoir dire parler manger
            boire dormir lire écrire écouter regarder chanter danser jouer travailler habiter aimer adorer détester
            préférer acheter vendre donner prendre mettre trouver chercher appeler ressembler penser croire
            comprendre apprendre connaître attendre entendre répondre ouvrir fermer partir sortir arriver rester
            tomber courir marcher nager voyager laver commencer finir choisir réussir nommer épouser divorcer grand
            grande petit petite beau bel belle joli jolie laid laide moche bon bonne mauvais mauvaise gentil
            gentille méchant méchante content contente heureux heureuse triste fatigué fatiguée malade jeune vieux
            vieille nouveau nouvelle blanc blanche noir noire rouge vert verte bleu bleue jaune gris grise marron
            facile difficile cher chère gros grosse long longue court courte chaud chaude froid froide sage brave
            aimable calme tranquille sérieux sérieuse sympathique charmant charmante raisonnable courageux
            courageuse bête lâche comique drôle marié mariée veuf veuve séparé séparée seul seule premier première
            dernier dernière intéressant ennuyeux génial vrai faux fausse attirant attirante poli polie timide
            paresseux paresseuse travailleur intelligent intelligente deux trois quatre cinq six sept huit neuf dix
            onze douze treize quatorze quinze seize vingt trente quarante cinquante soixante cent mille lundi mardi
            mercredi jeudi vendredi samedi dimanche janvier février mars avril mai juin juillet août septembre
            octobre novembre décembre
            """,
        .de: """
            herr herren mann männer frau frauen dame fräulein kind kinder junge mädchen name namen familienname
            nachname vorname person leute adresse anschrift strasse hausnummer haus wohnung zimmer küche garten
            schule klasse lehrer lehrerin schüler schülerin buch heft stift tisch stuhl tür fenster auto fahrrad zug
            flugzeug schiff hund katze vogel pferd fisch maus kuh schwein baum blume wasser brot käse milch fleisch
            apfel obst gemüse kaffee tee wein bier frühstück mittagessen abendessen tag nacht abend woche monat jahr
            stunde minute zeit wetter sonne regen schnee wind meer berg strand land wald fluss himmel erde welt
            arbeit beruf geld preis geschäft laden markt bäckerei bahnhof fahrkarte reise ferien urlaub musik lied
            spiel fest geburtstag geschenk kleidung hose hemd kleid rock schuh mantel hut kopf gesicht auge augen
            nase mund ohr haar haare hand arm bein fuss körper herz gesundheit arzt krankenhaus vernunft mut
            dummheit schönheit charme volk geschichte sprache wort satz frage antwort beispiel idee problem sache
            teil seite platz ende anfang freund freundin vater mutter bruder schwester eltern sohn tochter familie
            nachbar nachbarin sein haben werden machen gehen kommen sehen wissen sagen sprechen reden essen trinken
            schlafen lesen schreiben hören schauen singen tanzen spielen arbeiten wohnen lieben mögen hassen kaufen
            verkaufen geben nehmen legen stellen finden suchen nennen heissen ähneln gleichen denken glauben
            verstehen lernen kennen warten antworten öffnen schliessen fahren laufen bleiben fallen rennen schwimmen
            reisen waschen beginnen anfangen aufhören wählen helfen brauchen bekommen zeigen erklären erzählen
            fragen heiraten erscheinen gross grosse klein kleine schön hübsch hässlich gut schlecht lieb nett
            freundlich böse gemein glücklich traurig müde krank jung alt neu weiss schwarz rot grün blau gelb grau
            braun leicht schwer einfach teuer billig dick dünn lang kurz warm kalt heiss brav artig ruhig still
            komisch lustig ernst ernsthaft sympathisch vernünftig mutig feige dumm klug verheiratet verwitwet
            getrennt geschieden ledig allein erste letzte wichtig interessant langweilig toll wahr falsch richtig
            attraktiv anziehend gütig ähnlich gleich charmant höflich schüchtern faul fleissig eins zwei drei vier
            fünf sechs sieben acht neun zehn elf zwölf dreizehn vierzehn fünfzehn sechzehn siebzehn achtzehn
            neunzehn zwanzig dreissig vierzig fünfzig hundert tausend montag dienstag mittwoch donnerstag freitag
            samstag sonntag januar februar märz april mai juni juli august september oktober november dezember
            """,
        .en: """
            house home room kitchen garden school class teacher student pupil book pen table chair door window car
            bike train plane ship dog cat bird horse fish mouse cow pig tree flower water bread cheese milk meat
            apple fruit vegetable coffee tea wine beer breakfast lunch dinner day night morning evening week month
            year hour minute time weather sun rain snow wind sea mountain beach country forest river sky earth world
            work job money price shop market station ticket journey holiday sport music song film game party
            birthday present clothes trousers shirt dress skirt shoe coat hat head face eye eyes nose mouth ear hair
            hand arm leg foot body heart health doctor hospital people story language word sentence question answer
            example idea problem thing part side place end beginning friend father mother brother sister parents son
            daughter man woman child children boy girl name surname address street number family person neighbour
            neighbor appear be have do make go come see know say speak talk eat drink sleep read write listen hear
            look watch sing dance play live love like hate buy sell give take put find search call think believe
            understand learn wait answer open close leave stay fall run walk swim travel wash begin start finish
            choose help need get show explain tell ask become seem keep bring meet feel marry big small little
            beautiful pretty ugly good bad nice kind friendly angry happy sad tired ill sick young old new white
            black red green blue yellow grey gray brown easy difficult hard expensive cheap fat thin long short warm
            cold hot quiet calm funny serious brave clever stupid married single important interesting boring great
            true false right wrong first last polite shy lazy quickly slowly really happiness kindness building
            clothing lesson chapter exercise unit homework grammar vocabulary newspaper advertisement channel three
            four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen
            nineteen twenty thirty forty fifty hundred thousand monday tuesday wednesday thursday friday saturday
            sunday january february march april may june july august september october november december
            """,
        .es: """
            casa perro gato niño niña hombre mujer señor señora chico chica amigo amiga padre madre hermano hermana
            familia nombre apellido calle ciudad pueblo país escuela clase profesor alumno libro cuaderno mesa silla
            puerta ventana coche bicicleta tren avión barco pájaro caballo pez árbol flor agua pan queso leche carne
            manzana fruta verdura café té vino cerveza desayuno comida cena día noche mañana tarde semana mes año
            hora minuto tiempo sol lluvia nieve viento mar montaña playa campo bosque río cielo tierra mundo trabajo
            dinero precio tienda mercado estación billete viaje vacaciones deporte música canción película juego
            fiesta cumpleaños regalo ropa pantalones camisa vestido falda zapato abrigo sombrero cabeza cara ojo
            ojos nariz boca oreja pelo mano brazo pierna pie cuerpo corazón salud médico hospital gente historia
            idioma lengua palabra frase pregunta respuesta ejemplo idea problema cosa vez parte lado lugar fin
            principio momento universidad verdad libertad información hablar comer beber vivir dormir leer escribir
            escuchar mirar cantar bailar jugar trabajar amar querer odiar comprar vender dar tomar poner encontrar
            buscar llamar llamarse pensar creer entender aprender conocer esperar contestar abrir cerrar salir
            llegar quedarse caer correr andar caminar nadar viajar lavar empezar terminar elegir ayudar necesitar
            decir saber poder ver venir grande pequeño pequeña bonito bonita guapo guapa feo fea bueno buena malo
            mala simpático simpática antipático amable contento contenta feliz triste cansado cansada enfermo
            enferma joven viejo vieja nuevo nueva blanco blanca negro negra rojo roja verde azul amarillo gris
            marrón fácil difícil caro barato gordo delgado largo corto caliente frío fría tranquilo divertido serio
            valiente listo tonto casado soltero importante interesante aburrido dos tres cuatro cinco seis siete
            ocho nueve diez once doce trece catorce quince dieciséis veinte treinta cuarenta cincuenta cien mil
            lunes martes miércoles jueves viernes sábado domingo enero febrero marzo abril mayo junio julio agosto
            septiembre octubre noviembre diciembre
            """,
        .it: """
            casa cane gatto bambino bambina ragazzo ragazza uomo donna signore signora amico amica padre madre
            fratello sorella famiglia nome cognome indirizzo via strada città paese scuola classe professore
            studente studentessa libro quaderno penna tavolo sedia porta finestra macchina bicicletta treno aereo
            nave uccello cavallo pesce albero fiore acqua pane formaggio latte carne mela frutta verdura caffè vino
            birra colazione pranzo cena giorno notte mattina sera settimana mese anno ora minuto tempo sole pioggia
            neve vento mare montagna spiaggia campagna bosco fiume cielo terra mondo lavoro soldi prezzo negozio
            mercato stazione biglietto viaggio vacanze musica canzone gioco festa compleanno regalo vestiti
            pantaloni camicia vestito gonna scarpa cappotto cappello testa faccia viso occhio occhi naso bocca
            orecchio capelli mano braccio gamba piede corpo cuore salute medico ospedale gente storia lingua parola
            frase domanda risposta esempio idea problema volta parte lato posto fine inizio momento università
            libertà parlare mangiare bere vivere dormire leggere scrivere ascoltare guardare cantare ballare giocare
            lavorare abitare amare volere odiare comprare vendere dare prendere mettere trovare cercare chiamare
            chiamarsi pensare credere capire imparare conoscere aspettare rispondere aprire chiudere partire uscire
            arrivare restare cadere correre camminare nuotare viaggiare lavare cominciare finire scegliere aiutare
            dire sapere potere dovere vedere venire grande piccolo piccola bello bella brutto brutta buono buona
            cattivo cattiva simpatico simpatica gentile contento contenta felice triste stanco stanca malato malata
            giovane vecchio vecchia nuovo nuova bianco bianca nero nera rosso rossa verde azzurro blu giallo grigio
            marrone facile difficile caro cara economico grasso magro lungo lunga corto corta caldo calda freddo
            fredda tranquillo divertente serio coraggioso stupido sposato sposata importante interessante noioso due
            tre quattro cinque sei sette otto nove dieci undici dodici tredici quattordici quindici sedici venti
            trenta quaranta cinquanta cento mille lunedì martedì mercoledì giovedì venerdì sabato domenica gennaio
            febbraio marzo aprile maggio giugno luglio agosto settembre ottobre novembre dicembre
            """,
    ]

    /// `LEXICON_ONLY`: French words with German-looking "ei" / "ein" letter groups ("plein",
    /// "peindre"). They are known directly but kept out of the trigram model, which would otherwise
    /// make German "-ein" / "-einte" words ("vereint", "meinte") look French.
    ///
    /// Also greetings, thanks, yes/no and other first-lesson words. Alone on a side ("Bonjour
    /// Hallo", "Merci Danke") nothing else gives their language away, and the trigrams guess wrong
    /// ("Hallo" and "Merci" look Italian). Kept out of the trigram model so that the scores of all
    /// other words stay unchanged.
    static let lexiconOnly: [Lang: String] = [
        .fr: """
            plein pleine pleins pleines peine reine serein sereine sereins sereines frein freiner freinage peindre
            peint peinte peintre peinture atteindre atteinte éteindre éteinte craindre crainte ceinture teindre
            teinte feindre enceinte baleine haleine veine enseigner enseignant
            bonjour bonsoir salut coucou merci adieu revoir bientôt bienvenue bisous enchanté enchantée excusez
            désolé désolée félicitations volontiers accord
            """,
        .de: """
            hallo tschüss tschüs danke bitte ja nein guten wiedersehen willkommen entschuldigung verzeihung servus
            moin grüezi grüss salü tschau
            """,
        .en: """
            hello hi bye goodbye thanks thank please sorry welcome cheers
            """,
        .es: """
            hola adiós gracias perdón bienvenido bienvenida buenos buenas días noches tardes
            """,
        .it: """
            ciao grazie prego buongiorno buonasera buonanotte arrivederci benvenuto benvenuta scusa scusi
            """,
    ]
}
