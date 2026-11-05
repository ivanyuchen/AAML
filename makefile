
DIR = Lab4
LAB = AAML-Labs-2026
clone:
	mkdir -p $(DIR) && cd $(DIR) && git clone https://github.com/nycu-caslab/TinyRISC-V-SoC-Platform.git
	cd $(LAB) && git pull