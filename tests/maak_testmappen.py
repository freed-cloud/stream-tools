"""Bouwt een nagebootste versie van de mappen van playingparentsnl, om de Clip-poster te testen.

Gebruik:  python tests/maak_testmappen.py <doelmap>

- Echte bestandsnamen en echte teksten (tests/fixtures).
- De videobestanden zijn leeg; alleen de grootte telt (de Clip-poster koppelt titels via de
  bestandsgrootte). Alle groottes zijn door 1000 gedeeld, zodat de test weinig schijfruimte kost;
  de onderlinge verhoudingen blijven gelijk.
"""
import os
import shutil
import sys

HIER = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HIER, 'fixtures')
SCHAAL = 1000

ORIGINELEN = """11-16 15-14-01 m01 106838721|11-16 15-14-01 m02 107825733|11-16 15-14-01 m05 96216195|11-16 15-14-01 m06 65049876|11-16 15-14-01 m07 58008826|11-16 15-14-01 m08 33675654|11-16 15-14-01 m09 49430987|11-16 15-14-01 m10 6260808|11-16 15-14-01 m11 76482542|11-16 15-14-01 m12 65238029|11-16 15-14-01 m13 41922453|11-16 15-14-01 m14 33302612|11-16 15-14-01 m15 40101724|11-16 15-14-01 m18 52028657|11-16 15-14-01 m19 5575870|11-17 21-23-08 m02 51058704|11-17 21-23-08 m03 31338115|11-17 21-23-08 m06 20970332|11-17 21-23-08 m07 54089724|11-17 21-23-08 m09 46815007|11-18 22-05-45 m01 19614054|11-18 22-05-45 m02 25760049|11-18 22-05-45 m03 38410922|11-18 22-05-45 m04 56870249|11-18 22-05-45 m05 28079774|11-18 22-05-45 m06 63987115|11-18 22-05-45 m07 9111020|11-18 22-05-45 m08 23453980|11-19 16-47-23 m01 11155374|11-19 16-47-23 m02 38286974|11-19 16-47-23 m03 12533517|11-19 16-47-23 m04 8375768|11-19 16-47-23 m05 6492627|11-19 16-47-23 m06 12320201|11-19 16-47-23 m08 6813242|11-19 16-47-23 m26 4188411|11-19 16-47-23 m27 5825468|11-19 16-47-23 m15 9674465|11-21 09-10-44 m01 28808900"""
ARMA = """01 - Op patrouille door de havenstad 106838721|02 - Jeep-tocht door de bergen 107825733|05 - Met het busje het veld in 96216195|06 - Offroad door het bos 65049876|07 - Verstopt onder een wrak 58008826|08 - Busje vol, op naar de basis 33675654|09 - Volgas over de zandweg 49430987|10 - Plat op de grond bij de basisaanval 6260808|11 - Ambulancebusje dwars door het graan 76482542|12 - Dwars door het korenveld 65238029|13 - Busje, kaart en zandzakken 41922453|14 - Lachen om de route 33302612|15 - Achter het machinegeweer 40101724|18 - Ambulancebusje bij het kamp 52028657|19 - Basis veroverd 5575870|21 - Zelf aan het stuur 51058704|22 - Basis innemen door het hoge gras 31338115|25 - Rijden met een kompas in de hand 20970332|26 - Verstoppen in de bosjes 54089724|28 - Jeep-tocht langs de kust 46815007|30 - Wachten onder de tent 19625153|31 - Truck instappen en gaan 25764995|32 - Pantserwagen opent het vuur 38421792|33 - Binnen in de pantserwagen 56881126|34 - Pantserwagen door het dorp 28085860|35 - Bestorming van de basis 64000128"""
GTA = """02 - GTA 6 start eindelijk op - MUZIEK 7307067|03 - De eerste minuten van GTA 6 - MUZIEK 11162625|10 - Inbreken bij nacht - MUZIEK 6818136|17 - Avondje in de nachtclub - MUZIEK 9681420|28 - Jason in de slaapkamer - MUZIEK 4188411|29 - Jason denkt na - MUZIEK 5825468"""


def maak(pad, grootte=1000):
    with open(pad, 'wb') as f:
        f.truncate(max(1, grootte))


def main(root):
    shutil.rmtree(root, ignore_errors=True)
    socials = os.path.join(root, 'Desktop', 'Clips voor socials')
    vandaag = os.path.join(socials, 'Vandaag posten')
    ai = os.path.join(root, 'Videos', 'AI-clips')
    for d in (socials, vandaag, os.path.join(ai, 'Arma Reforger', 'Minder geschikt'),
              os.path.join(ai, 'GTA 6', 'Minder geschikt'), os.path.join(ai, 'Fall Guys'),
              os.path.join(socials, 'Instagram posten')):
        os.makedirs(d, exist_ok=True)
    for e in ORIGINELEN.split('|'):
        datum, tijd, m, s = e.split()
        maak(os.path.join(ai, 'Replay 2026-%s %s moment %s.mp4' % (datum, tijd, m[1:])), int(s) // SCHAAL)
    for map_, lijst in (('Arma Reforger', ARMA), ('GTA 6', GTA)):
        for e in lijst.split('|'):
            naam, s = e.rsplit(' ', 1)
            maak(os.path.join(ai, map_, naam + '.mp4'), int(s) // SCHAAL)
    maak(os.path.join(ai, 'Fall Guys', '01 - Overleven in Blastlantis.mp4'), 9117585 // SCHAAL)
    maak(os.path.join(ai, 'Fall Guys', '02 - Uitgeschakeld in Frantic Factory.mp4'), 23455250 // SCHAAL)
    teksten = os.path.join(FIX, 'teksten')
    for f in os.listdir(teksten):
        if f.endswith(' - tekst.txt'):
            shutil.copy(os.path.join(teksten, f), os.path.join(socials, f))
            maak(os.path.join(socials, f[:-len(' - tekst.txt')] + ' - staand.mp4'), 5000)
    # een staande clip zonder tekst (moet als probleem gemeld worden)
    maak(os.path.join(socials, 'Replay 2026-11-23 20-00-00 moment 01 - staand.mp4'))
    vp = os.path.join(FIX, 'vandaag-posten')
    for f in os.listdir(vp):
        if f.endswith('.txt'):
            shutil.copy(os.path.join(vp, f), os.path.join(vandaag, f))
            maak(os.path.join(vandaag, f[:-4] + '.mp4'), 7000)
    print('testmappen klaar:', root)


if __name__ == '__main__':
    main(sys.argv[1])
