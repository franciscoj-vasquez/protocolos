Estaremos en la tabla 82-5 a partir de ahora.. estaremo parados en 100gb. 

Viene la codificacion del lab 3, luego una transcodificacion scramble y desp ya los bloques que nos interesaran continura ahora. 

Inicialmente veremos lo relacionado a block distribution. Para 100ghz sera en 20 lanes. Cada 16383 aparee un aligment marker. A su vez estos vienen con un BIP que es un chequeo de integridad. Con ese aligment block puede tenerminar el orden del aligment block. A su vez tmb se agrega una compensation del skew que es basicamente poner en un buffer y poner cada marker a la misma altura. 

etapas: identificar ids de ccada carril. Luego reconstruir el skew (por si tenian retardo variado)

Nota curiosa, en lso markers los primeros (0-2) son los mismos que los siguientes pero negados. 

Los bits guardan la paridad --> el decodificador a su vez lo va calculando y comparando con las bips para levantar alguna flag en caso de error. 

Lanes logicas taza/lanes.. de la lane logica a la fisica puede variar en funcion de que tecnologia quieras usar, pero en cuyo caso se multiplexa y demultiplexa a la salida. 


--- 


Lab4 
Tomaremos desde el lab3 y lo distribuiremos en 20 lanes. Se achicara el periodo del alignment marker (no los 16k canonicos). 

En este caso se transmitira la info de donde esta el alignment marker con tx_lane_is_am.. (esto en la vida real no es asi, pero se simula para que sea mas seniclla la recepcion). La idea es encontrar los aligment marker y ver los codigos. (tabla 82-2).

Chequear cuantos bloques hay entre alignment blocks (parece que cada 128 ps, pero weno habria que explicarlo)